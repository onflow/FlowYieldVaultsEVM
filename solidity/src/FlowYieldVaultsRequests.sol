// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title FlowYieldVaultsRequests
 * @author Flow YieldVaults Team
 * @notice Request queue and fund escrow for EVM users to interact with Flow YieldVaults Cadence protocol
 * @dev This contract serves as an escrow and request queue for cross-VM operations between
 *      EVM and Cadence. Users deposit funds here, and the authorized COA (Cadence Owned Account)
 *      processes requests by bridging funds to Cadence and executing Flow YieldVaults operations.
 *
 *      Key flows:
 *      1. CREATE_YIELDVAULT: User deposits funds → COA bridges to Cadence → YieldVault created
 *      2. DEPOSIT_TO_YIELDVAULT: User deposits funds → COA bridges to existing YieldVault
 *      3. WITHDRAW_FROM_YIELDVAULT: User requests withdrawal → COA bridges funds back
 *      4. CLOSE_YIELDVAULT: User requests closure → COA closes YieldVault and bridges all funds back
 *
 *      Processing uses atomic two-phase commit:
 *      - startProcessingBatch(): Marks requests as PROCESSING, deducts user balances
 *      - completeProcessing(): Marks as COMPLETED/FAILED, credits claimable refunds on failure
 */
contract FlowYieldVaultsRequests is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ============================================
    // Type Declarations
    // ============================================

    /// @notice Types of requests that can be made to the Flow YieldVaults protocol
    enum RequestType {
        CREATE_YIELDVAULT,
        DEPOSIT_TO_YIELDVAULT,
        WITHDRAW_FROM_YIELDVAULT,
        CLOSE_YIELDVAULT
    }

    /// @notice Status of a request in the processing lifecycle
    enum RequestStatus {
        PENDING,
        PROCESSING,
        COMPLETED,
        FAILED
    }

    /// @notice Complete request data structure
    /// @param id Unique request identifier
    /// @param user Address of the user who created the request
    /// @param requestType Type of operation requested
    /// @param status Current status of the request
    /// @param tokenAddress Token being deposited/withdrawn (NATIVE_FLOW for native $FLOW)
    /// @param amount Amount of tokens involved
    /// @param yieldVaultId Associated YieldVault Id
    /// @param timestamp Block timestamp when request was created
    /// @param message Status message or error reason
    /// @param vaultIdentifier Cadence vault type identifier for CREATE_YIELDVAULT
    /// @param strategyIdentifier Cadence strategy type identifier for CREATE_YIELDVAULT
    struct Request {
        uint256 id;
        address user;
        RequestType requestType;
        RequestStatus status;
        address tokenAddress;
        uint256 amount;
        uint64 yieldVaultId;
        uint256 timestamp;
        string message;
        string vaultIdentifier;
        string strategyIdentifier;
    }

    /// @notice Configuration for supported tokens
    /// @param isSupported Whether the token can be used
    /// @param minimumBalance Minimum deposit amount required
    /// @param isNative True if this represents native $FLOW
    struct TokenConfig {
        bool isSupported;
        uint256 minimumBalance;
        bool isNative;
    }

    // ============================================
    // State Variables
    // ============================================

    /// @notice Sentinel address representing native $FLOW token
    /// @dev Uses recognizable pattern (all F's) instead of address(0) for clarity
    address public constant NATIVE_FLOW =
        0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    /// @notice Default minimum deposit for initially supported tokens
    uint256 public constant DEFAULT_MINIMUM_BALANCE = 1 ether;

    /// @notice WFLOW (Wrapped FLOW) ERC20 token address
    /// @dev On Cadence side, WFLOW is automatically unwrapped to native FlowToken by FlowEVMBridge
    address public immutable WFLOW;

    /// @notice Sentinel value for "no yieldvault"
    /// @dev Uses type(uint64).max since valid yieldVaultIds can be 0
    uint64 public constant NO_YIELDVAULT_ID = type(uint64).max;

    /// @dev Auto-incrementing counter for request IDs, starts at 1
    uint256 private _requestIdCounter;

    /// @notice Address of the authorized COA that can process requests
    address public authorizedCOA;

    /// @notice Whether allowlist enforcement is active
    bool public allowlistEnabled;

    /// @notice Addresses permitted to create requests when allowlist is enabled
    mapping(address => bool) public allowlisted;

    /// @notice Whether blocklist enforcement is active
    bool public blocklistEnabled;

    /// @notice Whether the contract is paused
    bool public paused;

    /// @notice Addresses blocked from creating requests
    mapping(address => bool) public blocklisted;

    /// @notice Token configurations indexed by token address
    mapping(address => TokenConfig) public allowedTokens;

    /// @notice Token addresses surfaced in per-user balance views
    address[] private _trackedTokens;

    /// @notice O(1) lookup for tracked-token membership
    mapping(address => bool) private _isTrackedToken;

    /// @notice Maximum number of pending requests allowed per user (0 = unlimited)
    uint256 public maxPendingRequestsPerUser;

    /// @notice Count of pending requests per user
    mapping(address => uint256) public userPendingRequestCount;

    /// @notice Pending request IDs per user for O(1) lookup
    mapping(address => uint256[]) public pendingRequestIdsByUser;

    /// @notice Index of request ID in user's pending array (for O(1) removal)
    mapping(uint256 => uint256) private _requestIndexInUserArray;

    /// @notice Registry of valid YieldVault Ids created through this contract
    mapping(uint64 => bool) public validYieldVaultIds;

    /// @notice Owner address for each YieldVault Id
    mapping(uint64 => address) public yieldVaultOwners;

    /// @notice Token address associated with each YieldVault Id
    mapping(uint64 => address) public yieldVaultTokens;

    /// @notice Array of YieldVault Ids owned by each user
    mapping(address => uint64[]) public yieldVaultsByUser;

    /// @notice O(1) lookup for yieldvault ownership verification
    mapping(address => mapping(uint64 => bool)) public userOwnsYieldVault;

    /// @notice Escrowed balances for active pending requests: user => token => amount
    mapping(address => mapping(address => uint256)) public pendingUserBalances;

    /// @notice Claimable refunds from cancelled/dropped/failed requests: user => token => amount
    mapping(address => mapping(address => uint256)) public claimableRefunds;

    /// @notice Total balance of each token accounted for in contract (escrowed/claimable)
    mapping(address => uint256) public totalAccountedBalance;

    /// @notice All requests indexed by request ID
    mapping(uint256 => Request) public requests;

    /// @notice Array of pending request IDs awaiting processing (FIFO order)
    uint256[] public pendingRequestIds;

    /// @notice Index of request ID in global pending array (for O(1) lookup)
    mapping(uint256 => uint256) private _requestIndexInGlobalArray;

    /// @notice Index of yieldVaultId in user's yieldVaultsByUser array (for O(1) removal)
    /// @dev Internal visibility allows test helpers to properly initialize state
    mapping(address => mapping(uint64 => uint256)) internal _yieldVaultIndexInUserArray;

    // ============================================
    // Errors
    // ============================================

    /// @notice Caller is not the authorized COA
    error NotAuthorizedCOA(address sender);

    /// @notice Caller is not in the allowlist
    error NotInAllowlist(address sender);

    /// @notice Caller is in the blocklist
    error Blocklisted(address sender);

    /// @notice COA address cannot be zero
    error InvalidCOAAddress();

    /// @notice Minimum balance must be non-zero for supported tokens
    error InvalidMinimumBalance();

    /// @notice Address array cannot be empty
    error EmptyAddressArray();

    /// @notice Cannot add zero address to allowlist
    error CannotAllowlistZeroAddress();

    /// @notice Cannot add zero address to blocklist
    error CannotBlocklistZeroAddress();

    /// @notice Amount must be greater than zero
    error AmountMustBeGreaterThanZero();

    /// @notice msg.value must equal amount for native token deposits
    error MsgValueMustEqualAmount();

    /// @notice msg.value must be zero for ERC20 deposits
    error MsgValueMustBeZero();

    /// @notice Token is not configured as supported
    error TokenNotSupported(address token);

    /// @notice Request ID does not exist
    error RequestNotFound();

    /// @notice Caller is not the request owner
    error NotRequestOwner();

    /// @notice Can only cancel requests in PENDING status
    error CanOnlyCancelPending();

    /// @notice Request is not in expected status for this operation
    error InvalidRequestState();

    /// @notice Insufficient balance for withdrawal
    error InsufficientBalance(
        address token,
        uint256 requested,
        uint256 available
    );

    /// @notice Native token transfer failed
    error TransferFailed();

    /// @notice Deposit amount is below minimum requirement
    error BelowMinimumBalance(address token, uint256 amount, uint256 minimum);

    /// @notice User has too many pending requests
    error TooManyPendingRequests();

    /// @notice YieldVault Id is invalid or not owned by user
    error InvalidYieldVaultId(uint64 yieldVaultId, address user);

    /// @notice YieldVault Id has already been registered
    error YieldVaultIdAlreadyRegistered(uint64 yieldVaultId);

    /// @notice YieldVault Id does not match the request's value
    error YieldVaultIdMismatch(uint64 expectedId, uint64 providedId);

    /// @notice YieldVault token is not set
    error YieldVaultTokenNotSet(uint64 yieldVaultId);

    /// @notice Cannot register sentinel value NO_YIELDVAULT_ID as a valid YieldVault
    error CannotRegisterSentinelYieldVaultId();

    /// @notice Token does not match YieldVault's configured token
    error YieldVaultTokenMismatch(
        uint64 yieldVaultId,
        address expected,
        address provided
    );

    /// @notice Contract is paused
    error ContractPaused();

    /// @notice Vault identifier cannot be empty for CREATE_YIELDVAULT
    error EmptyVaultIdentifier();

    /// @notice Strategy identifier cannot be empty for CREATE_YIELDVAULT
    error EmptyStrategyIdentifier();

    /// @notice No refund available for the specified token
    error NoRefundAvailable(address token);

    /// @notice Recovery user address cannot be zero
    error InvalidRecoveryUserAddress();

    /// @notice ERC20 token address cannot be the native $FLOW token
    error InvalidRecoveryTokenAddress();

    /// @notice The requested recovery amount exceeds the available excess amount
    error InsufficientRecoveryAmount(uint256 available, uint256 requested);

    // ============================================
    // Events
    // ============================================

    /// @notice Emitted when a new request is created
    /// @param requestId Unique identifier for the request
    /// @param user Address of the user who created the request
    /// @param requestType Type of operation requested
    /// @param tokenAddress Token involved in the request
    /// @param amount Amount of tokens
    /// @param yieldVaultId Associated YieldVault Id
    /// @param timestamp Block timestamp when request was created
    /// @param vaultIdentifier Cadence vault type identifier (for CREATE_YIELDVAULT)
    /// @param strategyIdentifier Cadence strategy type identifier (for CREATE_YIELDVAULT)
    event RequestCreated(
        uint256 indexed requestId,
        address indexed user,
        RequestType requestType,
        address indexed tokenAddress,
        uint256 amount,
        uint64 yieldVaultId,
        uint256 timestamp,
        string vaultIdentifier,
        string strategyIdentifier
    );

    /// @notice Emitted when a request status changes
    /// @param requestId Request being updated
    /// @param user Address of the user who owns the request
    /// @param requestType Type of operation being processed
    /// @param status New status
    /// @param yieldVaultId Associated YieldVault Id
    /// @param message Status message or error reason
    event RequestProcessed(
        uint256 indexed requestId,
        address indexed user,
        RequestType requestType,
        RequestStatus status,
        uint64 yieldVaultId,
        string message
    );

    /// @notice Emitted when a request is cancelled (by user or admin)
    /// @param requestId Cancelled request ID
    /// @param user Address that cancelled (user or admin)
    /// @param tokenAddress Token that can be claimed via claimRefund()
    /// @param claimableAmount Amount available to claim (0 for WITHDRAW/CLOSE requests)
    event RequestCancelled(
        uint256 indexed requestId,
        address indexed user,
        address indexed tokenAddress,
        uint256 claimableAmount
    );

    /// @notice Emitted when a refund becomes claimable
    /// @param user User who can claim the refund
    /// @param tokenAddress Token address
    /// @param amount Amount added to claimableRefunds
    /// @param requestId Request that generated the refund
    event RefundCredited(
        address indexed user,
        address indexed tokenAddress,
        uint256 amount,
        uint256 indexed requestId
    );

    /// @notice Emitted when user's escrowed balance changes
    /// @param user User address
    /// @param tokenAddress Token address
    /// @param newBalance Updated balance
    event BalanceUpdated(
        address indexed user,
        address indexed tokenAddress,
        uint256 newBalance
    );

    /// @notice Emitted when funds are withdrawn from the contract
    /// @param to Recipient address
    /// @param tokenAddress Token withdrawn
    /// @param amount Amount withdrawn
    event FundsWithdrawn(
        address indexed to,
        address indexed tokenAddress,
        uint256 amount
    );

    /// @notice Emitted when authorized COA is changed
    /// @param oldCOA Previous COA address
    /// @param newCOA New COA address
    event AuthorizedCOAUpdated(address indexed oldCOA, address indexed newCOA);

    /// @notice Emitted when allowlist status changes
    /// @param enabled New status
    /// @param changedBy Admin who changed the status
    event AllowlistEnabled(bool enabled, address indexed changedBy);

    /// @notice Emitted when addresses are added to allowlist
    /// @param addresses Addresses added
    /// @param addedBy Admin who added the addresses
    event AddressesAddedToAllowlist(address[] addresses, address indexed addedBy);

    /// @notice Emitted when addresses are removed from allowlist
    /// @param addresses Addresses removed
    /// @param removedBy Admin who removed the addresses
    event AddressesRemovedFromAllowlist(address[] addresses, address indexed removedBy);

    /// @notice Emitted when blocklist status changes
    /// @param enabled New status
    /// @param changedBy Admin who changed the status
    event BlocklistEnabled(bool enabled, address indexed changedBy);

    /// @notice Emitted when addresses are added to blocklist
    /// @param addresses Addresses added
    /// @param addedBy Admin who added the addresses
    event AddressesAddedToBlocklist(address[] addresses, address indexed addedBy);

    /// @notice Emitted when addresses are removed from blocklist
    /// @param addresses Addresses removed
    /// @param removedBy Admin who removed the addresses
    event AddressesRemovedFromBlocklist(address[] addresses, address indexed removedBy);

    /// @notice Emitted when token configuration changes
    /// @param token Token address
    /// @param isSupported Whether token is supported
    /// @param minimumBalance Minimum deposit amount
    /// @param isNative Whether token is native $FLOW
    /// @param configuredBy Admin who configured the token
    event TokenConfigured(
        address indexed token,
        bool isSupported,
        uint256 minimumBalance,
        bool isNative,
        address indexed configuredBy
    );

    /// @notice Emitted when max pending requests limit changes
    /// @param oldMax Previous limit
    /// @param newMax New limit
    /// @param updatedBy Admin who updated the limit
    event MaxPendingRequestsPerUserUpdated(uint256 oldMax, uint256 newMax, address indexed updatedBy);

    /// @notice Emitted when the contract is paused
    /// @param account Address that paused the contract
    event Paused(address account);

    /// @notice Emitted when the contract is unpaused
    /// @param account Address that unpaused the contract
    event Unpaused(address account);

    /// @notice Emitted when a new YieldVault is registered
    /// @param yieldVaultId Newly registered YieldVault Id
    /// @param owner Address of the YieldVault owner
    /// @param requestId Request ID that created this YieldVault
    event YieldVaultIdRegistered(uint64 indexed yieldVaultId, address indexed owner, uint256 indexed requestId);

    /// @notice Emitted when a YieldVault is unregistered (closed)
    /// @param yieldVaultId Unregistered YieldVault Id
    /// @param owner Address of the former YieldVault owner
    /// @param requestId Request ID that closed this YieldVault
    event YieldVaultIdUnregistered(uint64 indexed yieldVaultId, address indexed owner, uint256 indexed requestId);

    /// @notice Emitted when requests are dropped
    /// @param requestIds Dropped request IDs
    /// @param droppedBy Admin/COA who dropped the requests
    event RequestsDropped(uint256[] requestIds, address indexed droppedBy);

    /// @notice Emitted when a user claims their refund
    /// @param user User who claimed the refund
    /// @param tokenAddress Token claimed
    /// @param amount Amount claimed
    event RefundClaimed(
        address indexed user,
        address indexed tokenAddress,
        uint256 amount
    );

    /// @notice Emitted when the contract owner recovers user tokens
    /// @param to User who received the tokens
    /// @param tokenAddress ERC20 token claimed
    /// @param amount Amount recovered
    event TokensRecovered(
        address indexed to,
        address indexed tokenAddress,
        uint256 amount
    );

    // ============================================
    // Modifiers
    // ============================================

    /// @dev Restricts function to authorized COA only
    modifier onlyAuthorizedCOA() {
        if (msg.sender != authorizedCOA) revert NotAuthorizedCOA(msg.sender);
        _;
    }

    /// @dev Requires caller to be allowlisted (if allowlist is enabled)
    modifier onlyAllowlisted() {
        if (allowlistEnabled && !allowlisted[msg.sender]) {
            revert NotInAllowlist(msg.sender);
        }
        _;
    }

    /// @dev Requires caller to not be blocklisted (if blocklist is enabled)
    modifier notBlocklisted() {
        if (blocklistEnabled && blocklisted[msg.sender]) {
            revert Blocklisted(msg.sender);
        }
        _;
    }

    /// @dev Requires contract to not be paused
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    // ============================================
    // Constructor
    // ============================================

    /// @notice Initializes the contract with COA address and default configuration
    /// @param coaAddress Address of the authorized COA
    /// @param wflowAddress Address of the WFLOW (Wrapped FLOW) ERC20 token
    constructor(address coaAddress, address wflowAddress) Ownable(msg.sender) {
        if (coaAddress == address(0)) revert InvalidCOAAddress();

        authorizedCOA = coaAddress;
        WFLOW = wflowAddress;
        _requestIdCounter = 1;
        maxPendingRequestsPerUser = 10;

        _setTokenConfig(NATIVE_FLOW, true, DEFAULT_MINIMUM_BALANCE, true);

        // WFLOW is treated as ERC20 on EVM side, but unwraps to native FlowToken on Cadence
        if (wflowAddress != address(0)) {
            _setTokenConfig(WFLOW, true, DEFAULT_MINIMUM_BALANCE, false);
        }
    }

    // ============================================
    // External Functions - Admin
    // ============================================

    /// @notice Recovery mechanism for accidental user transfers of ERC20 tokens
    /// @dev Tokens sent directly to the contract outside the intended request
    ///      flows (including accidental transfers, airdrops etc) are only
    ///      recoverable through this function here.
    /// @param to The recipient address to transfer funds to.
    /// @param tokenAddress The token to transfer.
    /// @param amount The amount of tokens to transfer (in wei).
    function recoverTokens(
        address to,
        address tokenAddress,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (to == address(0) || to == address(this))
            revert InvalidRecoveryUserAddress();
        if (isNativeFlow(tokenAddress)) revert InvalidRecoveryTokenAddress();
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        uint256 contractBalance = IERC20(tokenAddress).balanceOf(address(this));
        uint256 excess = contractBalance > totalAccountedBalance[tokenAddress]
            ? contractBalance - totalAccountedBalance[tokenAddress]
            : 0;
        if (amount > excess) {
            revert InsufficientRecoveryAmount(excess, amount);
        }

        IERC20(tokenAddress).safeTransfer(to, amount);
        emit TokensRecovered(to, tokenAddress, amount);
    }

    /// @notice Updates the authorized COA address
    /// @param _coa New COA address
    function setAuthorizedCOA(address _coa) external onlyOwner {
        if (_coa == address(0)) revert InvalidCOAAddress();
        address oldCOA = authorizedCOA;
        authorizedCOA = _coa;
        emit AuthorizedCOAUpdated(oldCOA, _coa);
    }

    /// @notice Enables or disables allowlist enforcement
    /// @param _enabled True to enable, false to disable
    function setAllowlistEnabled(bool _enabled) external onlyOwner {
        allowlistEnabled = _enabled;
        emit AllowlistEnabled(_enabled, msg.sender);
    }

    /// @notice Adds multiple addresses to the allowlist
    /// @param _addresses Addresses to add
    function batchAddToAllowlist(
        address[] calldata _addresses
    ) external onlyOwner {
        if (_addresses.length == 0) revert EmptyAddressArray();

        for (uint256 i = 0; i < _addresses.length; ) {
            if (_addresses[i] == address(0))
                revert CannotAllowlistZeroAddress();
            allowlisted[_addresses[i]] = true;
            unchecked {
                ++i;
            }
        }

        emit AddressesAddedToAllowlist(_addresses, msg.sender);
    }

    /// @notice Removes multiple addresses from the allowlist
    /// @param _addresses Addresses to remove
    function batchRemoveFromAllowlist(
        address[] calldata _addresses
    ) external onlyOwner {
        if (_addresses.length == 0) revert EmptyAddressArray();

        for (uint256 i = 0; i < _addresses.length; ) {
            allowlisted[_addresses[i]] = false;
            unchecked {
                ++i;
            }
        }

        emit AddressesRemovedFromAllowlist(_addresses, msg.sender);
    }

    /// @notice Enables or disables blocklist enforcement
    /// @param _enabled True to enable, false to disable
    function setBlocklistEnabled(bool _enabled) external onlyOwner {
        blocklistEnabled = _enabled;
        emit BlocklistEnabled(_enabled, msg.sender);
    }

    /// @notice Adds multiple addresses to the blocklist
    /// @param _addresses Addresses to add
    function batchAddToBlocklist(
        address[] calldata _addresses
    ) external onlyOwner {
        if (_addresses.length == 0) revert EmptyAddressArray();

        for (uint256 i = 0; i < _addresses.length; ) {
            if (_addresses[i] == address(0))
                revert CannotBlocklistZeroAddress();
            blocklisted[_addresses[i]] = true;
            unchecked {
                ++i;
            }
        }

        emit AddressesAddedToBlocklist(_addresses, msg.sender);
    }

    /// @notice Removes multiple addresses from the blocklist
    /// @param _addresses Addresses to remove
    function batchRemoveFromBlocklist(
        address[] calldata _addresses
    ) external onlyOwner {
        if (_addresses.length == 0) revert EmptyAddressArray();

        for (uint256 i = 0; i < _addresses.length; ) {
            blocklisted[_addresses[i]] = false;
            unchecked {
                ++i;
            }
        }

        emit AddressesRemovedFromBlocklist(_addresses, msg.sender);
    }

    /// @notice Configures token support and requirements
    /// @param tokenAddress Token to configure
    /// @param isSupported Whether the token is supported
    /// @param minimumBalance Minimum deposit amount (in wei)
    /// @param isNative Whether this represents native $FLOW
    function setTokenConfig(
        address tokenAddress,
        bool isSupported,
        uint256 minimumBalance,
        bool isNative
    ) external onlyOwner {
        _setTokenConfig(tokenAddress, isSupported, minimumBalance, isNative);

        emit TokenConfigured(
            tokenAddress,
            isSupported,
            minimumBalance,
            isNative,
            msg.sender
        );
    }

    /// @notice Sets the maximum pending requests allowed per user
    /// @param _maxRequests New limit (0 = unlimited)
    function setMaxPendingRequestsPerUser(
        uint256 _maxRequests
    ) external onlyOwner {
        uint256 oldMax = maxPendingRequestsPerUser;
        maxPendingRequestsPerUser = _maxRequests;
        emit MaxPendingRequestsPerUserUpdated(oldMax, _maxRequests, msg.sender);
    }

    /// @notice Pauses the contract, preventing new request creation
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpauses the contract, allowing new request creation
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Drops pending requests. Escrowed funds are moved to claimableRefunds.
     * @dev Admin-only cleanup function for removing stuck or problematic requests.
     *      Silently skips requests that don't exist or aren't in PENDING status.
     *      For CREATE/DEPOSIT requests, escrowed funds are moved to claimableRefunds
     *      and can be withdrawn by calling claimRefund() (pull pattern).
     *      WITHDRAW/CLOSE requests have no escrowed funds, so only status is updated.
     * @param requestIds Array of request IDs to drop. Invalid/non-pending IDs are skipped.
     */
    function dropRequests(
        uint256[] calldata requestIds
    ) external onlyOwner nonReentrant {
        _dropRequestsInternal(requestIds);
    }

    // ============================================
    // External Functions - User
    // ============================================

    /// @notice Creates a new YieldVault by depositing funds
    /// @param tokenAddress Token to deposit (use NATIVE_FLOW for native $FLOW)
    /// @param amount Amount to deposit
    /// @param vaultIdentifier Cadence vault type identifier
    /// @param strategyIdentifier Cadence strategy type identifier
    /// @return requestId The created request ID
    function createYieldVault(
        address tokenAddress,
        uint256 amount,
        string calldata vaultIdentifier,
        string calldata strategyIdentifier
    )
        external
        payable
        whenNotPaused
        onlyAllowlisted
        notBlocklisted
        nonReentrant
        returns (uint256)
    {
        // Validate identifiers are not empty (fail fast before escrowing funds)
        if (bytes(vaultIdentifier).length == 0) revert EmptyVaultIdentifier();
        if (bytes(strategyIdentifier).length == 0)
            revert EmptyStrategyIdentifier();

        _validateDeposit(tokenAddress, amount);
        _checkPendingRequestLimit(msg.sender);

        return
            _createRequest(
                RequestType.CREATE_YIELDVAULT,
                tokenAddress,
                amount,
                NO_YIELDVAULT_ID,
                vaultIdentifier,
                strategyIdentifier
            );
    }

    /// @notice Deposits additional funds to an existing YieldVault
    /// @param yieldVaultId YieldVault Id to deposit to
    /// @param tokenAddress Token to deposit
    /// @param amount Amount to deposit
    /// @return requestId The created request ID
    function depositToYieldVault(
        uint64 yieldVaultId,
        address tokenAddress,
        uint256 amount
    )
        external
        payable
        whenNotPaused
        onlyAllowlisted
        notBlocklisted
        nonReentrant
        returns (uint256)
    {
        if (!validYieldVaultIds[yieldVaultId])
            revert InvalidYieldVaultId(yieldVaultId, msg.sender);
        address vaultToken = yieldVaultTokens[yieldVaultId];
        if (vaultToken == address(0)) revert YieldVaultTokenNotSet(yieldVaultId);
        if (vaultToken != tokenAddress)
            revert YieldVaultTokenMismatch(yieldVaultId, vaultToken, tokenAddress);

        _validateDeposit(tokenAddress, amount);
        _checkPendingRequestLimit(msg.sender);

        return
            _createRequest(
                RequestType.DEPOSIT_TO_YIELDVAULT,
                vaultToken,
                amount,
                yieldVaultId,
                "",
                ""
            );
    }

    /// @notice Requests a withdrawal from an existing YieldVault
    /// @param yieldVaultId YieldVault Id to withdraw from
    /// @param amount Amount to withdraw
    /// @return requestId The created request ID
    function withdrawFromYieldVault(
        uint64 yieldVaultId,
        uint256 amount
    ) external whenNotPaused onlyAllowlisted notBlocklisted returns (uint256) {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        _validateYieldVaultOwnership(yieldVaultId, msg.sender);
        address vaultToken = yieldVaultTokens[yieldVaultId];
        if (vaultToken == address(0)) revert YieldVaultTokenNotSet(yieldVaultId);
        _checkPendingRequestLimit(msg.sender);

        return
            _createRequest(
                RequestType.WITHDRAW_FROM_YIELDVAULT,
                vaultToken,
                amount,
                yieldVaultId,
                "",
                ""
            );
    }

    /// @notice Requests closure of a YieldVault and withdrawal of all funds
    /// @param yieldVaultId YieldVault Id to close
    /// @return requestId The created request ID
    function closeYieldVault(
        uint64 yieldVaultId
    ) external whenNotPaused onlyAllowlisted notBlocklisted returns (uint256) {
        _validateYieldVaultOwnership(yieldVaultId, msg.sender);
        address vaultToken = yieldVaultTokens[yieldVaultId];
        if (vaultToken == address(0)) revert YieldVaultTokenNotSet(yieldVaultId);
        _checkPendingRequestLimit(msg.sender);

        return
            _createRequest(
                RequestType.CLOSE_YIELDVAULT,
                vaultToken,
                0,
                yieldVaultId,
                "",
                ""
            );
    }

    /**
     * @notice Cancels a pending request. Escrowed funds are moved to claimableRefunds.
     * @dev Can be called by the request owner or the contract owner (admin).
     *      Only PENDING requests can be cancelled. Requests already in PROCESSING,
     *      COMPLETED, or FAILED status cannot be cancelled.
     *      For CREATE/DEPOSIT requests, escrowed funds are moved to claimableRefunds
     *      and can be withdrawn by calling claimRefund() (pull pattern).
     *      For WITHDRAW/CLOSE requests, no funds are escrowed, so no refund occurs.
     * @param requestId The unique identifier of the request to cancel.
     */
    function cancelRequest(uint256 requestId) external nonReentrant {
        Request storage request = requests[requestId];

        // === VALIDATION ===
        // Verify request exists (id field matches means request was properly initialized)
        if (request.id != requestId) revert RequestNotFound();
        // Only request owner or contract owner can cancel
        if (request.user != msg.sender && msg.sender != owner())
            revert NotRequestOwner();
        // Only PENDING requests can be cancelled (not PROCESSING/COMPLETED/FAILED)
        if (request.status != RequestStatus.PENDING)
            revert CanOnlyCancelPending();

        // === UPDATE REQUEST STATUS ===
        request.status = RequestStatus.FAILED;
        // Set appropriate message based on who cancelled
        string memory cancelMessage = msg.sender == request.user
            ? "Cancelled by user"
            : "Cancelled by admin";
        request.message = cancelMessage;

        // === UPDATE PENDING COUNTS AND QUEUES ===
        if (userPendingRequestCount[request.user] > 0) {
            userPendingRequestCount[request.user]--;
        }
        _removePendingRequest(requestId);

        // === REFUND HANDLING (pull pattern) ===
        // For CREATE/DEPOSIT requests, move funds from pendingUserBalances to claimableRefunds
        // User must call claimRefund() to withdraw them
        // WITHDRAW/CLOSE requests don't escrow funds, so nothing to do
        uint256 claimableAmount = 0;
        if (
            (request.requestType == RequestType.CREATE_YIELDVAULT ||
                request.requestType == RequestType.DEPOSIT_TO_YIELDVAULT) &&
            request.amount > 0
        ) {
            claimableAmount = request.amount;
            // Move from escrowed balance to claimable refunds
            uint256 newBalance =
                pendingUserBalances[request.user][request.tokenAddress] -
                    claimableAmount;
            pendingUserBalances[request.user][request.tokenAddress] = newBalance;
            emit BalanceUpdated(
                request.user,
                request.tokenAddress,
                newBalance
            );
            claimableRefunds[request.user][request.tokenAddress] += claimableAmount;
            emit RefundCredited(
                request.user,
                request.tokenAddress,
                claimableAmount,
                requestId
            );
        }

        // === EMIT EVENTS ===
        emit RequestCancelled(requestId, msg.sender, request.tokenAddress, claimableAmount);
        emit RequestProcessed(
            requestId,
            request.user,
            request.requestType,
            RequestStatus.FAILED,
            request.yieldVaultId,
            cancelMessage
        );
    }

    /// @notice Claims all refunded funds for a specific token
    /// @dev Refunds accumulate in claimableRefunds when requests are cancelled, dropped, or fail.
    ///      This function allows users to withdraw those funds. Does NOT touch funds escrowed
    ///      for active pending requests (pendingUserBalances).
    /// @param tokenAddress Token to claim refund for (NATIVE_FLOW or ERC20)
    function claimRefund(address tokenAddress) external nonReentrant {
        uint256 balance = claimableRefunds[msg.sender][tokenAddress];
        if (balance == 0) revert NoRefundAvailable(tokenAddress);

        claimableRefunds[msg.sender][tokenAddress] = 0;

        _transferFunds(msg.sender, tokenAddress, balance);

        emit FundsWithdrawn(msg.sender, tokenAddress, balance);
        emit RefundClaimed(msg.sender, tokenAddress, balance);
    }

    // ============================================
    // External Functions - COA
    // ============================================

    /**
     * @notice Processes a batch of PENDING requests.
     * @dev For successful requests, marks them as PROCESSING.
     *      For rejected requests, marks them as FAILED.
     *      Single-request processing is supported by passing one request id in
     *      successfulRequestIds and an empty rejectedRequestIds array.
     * @param successfulRequestIds The request ids to start processing (PENDING -> PROCESSING)
     * @param rejectedRequestIds The request ids to drop (PENDING -> FAILED)
     */
    function startProcessingBatch(
        uint256[] calldata successfulRequestIds,
        uint256[] calldata rejectedRequestIds
    ) external onlyAuthorizedCOA nonReentrant {

        // === REJECTED REQUESTS ===
        _dropRequestsInternal(rejectedRequestIds);

        // === SUCCESSFUL REQUESTS ===
        for (uint256 i = 0; i < successfulRequestIds.length; ) {
            _startProcessingInternal(successfulRequestIds[i]);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Completes request processing by marking success/failure and handling refunds.
     * @dev This is the second phase of the two-phase commit pattern. Must be called by the
     *      authorized COA after Cadence-side operations complete.
     *
     *      Refund handling (for failed CREATE/DEPOSIT requests only):
     *      - Native FLOW: COA must send exact amount via msg.value
     *      - ERC20: COA must approve this contract, funds are pulled via safeTransferFrom
     *      - Refunded funds are credited to user's claimableRefunds for later claim
     *
     *      YieldVault registration:
     *      - Successful CREATE: Registers new YieldVault ownership
     *      - Successful CLOSE: Unregisters YieldVault ownership
     *
     *      For all other cases (success, WITHDRAW/CLOSE), msg.value must be 0.
     * @param requestId The unique identifier of the request to complete.
     * @param success True if the Cadence operation succeeded, false otherwise.
     * @param yieldVaultId The YieldVault Id from Cadence (for CREATE: newly assigned; for others: existing).
     * @param message Human-readable status message or error description.
     */
    function completeProcessing(
        uint256 requestId,
        bool success,
        uint64 yieldVaultId,
        string calldata message
    ) external payable onlyAuthorizedCOA nonReentrant {
        Request storage request = requests[requestId];

        // === VALIDATION ===
        if (request.id != requestId) revert RequestNotFound();
        // Only PROCESSING requests can be completed (must call startProcessingBatch first)
        if (request.status != RequestStatus.PROCESSING)
            revert InvalidRequestState();

        // === UPDATE REQUEST STATUS ===
        RequestStatus newStatus = success
            ? RequestStatus.COMPLETED
            : RequestStatus.FAILED;
        request.status = newStatus;
        request.message = message;

        // Enforce strong ID binding for DEPOSIT/WITHDRAW/CLOSE by requiring the
        // supplied yieldVaultId matches the request's stored yieldVaultId
        if (request.requestType == RequestType.CREATE_YIELDVAULT) {
            request.yieldVaultId = yieldVaultId;
        } else if (request.yieldVaultId != yieldVaultId) {
            revert YieldVaultIdMismatch(request.yieldVaultId, yieldVaultId);
        }

        // === HANDLE REFUNDS FOR FAILED CREATE/DEPOSIT ===
        // COA must return the funds that were transferred in startProcessingBatch
        if (
            !success &&
            (request.requestType == RequestType.CREATE_YIELDVAULT ||
                request.requestType == RequestType.DEPOSIT_TO_YIELDVAULT)
        ) {
            if (isNativeFlow(request.tokenAddress)) {
                // Native FLOW: must be sent with this transaction
                if (msg.value != request.amount) revert MsgValueMustEqualAmount();
            } else {
                // ERC20: pull from COA (requires prior approval)
                if (msg.value != 0) revert MsgValueMustBeZero();
                IERC20(request.tokenAddress).safeTransferFrom(
                    msg.sender,
                    address(this),
                    request.amount
                );
                totalAccountedBalance[request.tokenAddress] += request.amount;
            }
            // Credit refunded funds to claimable refunds for later claim
            claimableRefunds[request.user][request.tokenAddress] += request
                .amount;
            emit RefundCredited(
                request.user,
                request.tokenAddress,
                request.amount,
                requestId
            );
        } else {
            // No refund expected for: successful requests OR WITHDRAW/CLOSE requests
            if (msg.value != 0) revert MsgValueMustBeZero();
        }

        // === UPDATE YIELDVAULT REGISTRY ===
        // Register new YieldVault on successful CREATE
        if (success && request.requestType == RequestType.CREATE_YIELDVAULT) {
            _registerYieldVault(
                yieldVaultId,
                request.user,
                request.tokenAddress,
                requestId
            );
        }
        // Unregister YieldVault on successful CLOSE
        if (success && request.requestType == RequestType.CLOSE_YIELDVAULT) {
            _unregisterYieldVault(yieldVaultId, request.user, requestId);
        }

        emit RequestProcessed(requestId, request.user, request.requestType, newStatus, yieldVaultId, message);
    }

    // ============================================
    // External Functions - View
    // ============================================

    /// @notice Checks if a token is configured as native $FLOW
    /// @param tokenAddress Token to check
    /// @return True if token is native $FLOW
    function isNativeFlow(address tokenAddress) public view returns (bool) {
        return allowedTokens[tokenAddress].isNative;
    }

    /// @notice Gets a user's escrowed balance for a token (funds tied to active pending requests)
    /// @param user User address
    /// @param tokenAddress Token address
    /// @return Escrowed balance for active pending requests
    function getUserPendingBalance(
        address user,
        address tokenAddress
    ) external view returns (uint256) {
        return pendingUserBalances[user][tokenAddress];
    }

    /// @notice Gets a user's claimable refund balance for a token
    /// @dev This is the amount available to withdraw via claimRefund()
    /// @param user User address
    /// @param tokenAddress Token address
    /// @return Claimable refund amount
    function getClaimableRefund(
        address user,
        address tokenAddress
    ) external view returns (uint256) {
        return claimableRefunds[user][tokenAddress];
    }

    /// @notice Gets the count of pending requests
    /// @return Number of pending requests
    function getPendingRequestCount() external view returns (uint256) {
        return pendingRequestIds.length;
    }

    /// @notice Gets all pending request IDs
    /// @return Array of pending request IDs
    function getPendingRequestIds() external view returns (uint256[] memory) {
        return pendingRequestIds;
    }

    /// @notice Gets pending requests in unpacked format with pagination
    /// @dev Optimized for Cadence consumption - returns parallel arrays instead of struct array
    /// @param startIndex Starting index in pending requests
    /// @param count Number of requests to return (0 = all remaining)
    /// @return ids Request IDs
    /// @return users User addresses
    /// @return requestTypes Request types
    /// @return statuses Request statuses
    /// @return tokenAddresses Token addresses
    /// @return amounts Amounts
    /// @return yieldVaultIds YieldVault Ids
    /// @return timestamps Timestamps
    /// @return messages Messages
    /// @return vaultIdentifiers Vault identifiers
    /// @return strategyIdentifiers Strategy identifiers
    function getPendingRequestsUnpacked(
        uint256 startIndex,
        uint256 count
    )
        external
        view
        returns (
            uint256[] memory ids,
            address[] memory users,
            uint8[] memory requestTypes,
            uint8[] memory statuses,
            address[] memory tokenAddresses,
            uint256[] memory amounts,
            uint64[] memory yieldVaultIds,
            uint256[] memory timestamps,
            string[] memory messages,
            string[] memory vaultIdentifiers,
            string[] memory strategyIdentifiers
        )
    {
        if (startIndex >= pendingRequestIds.length) {
            return (
                new uint256[](0),
                new address[](0),
                new uint8[](0),
                new uint8[](0),
                new address[](0),
                new uint256[](0),
                new uint64[](0),
                new uint256[](0),
                new string[](0),
                new string[](0),
                new string[](0)
            );
        }

        uint256 remaining = pendingRequestIds.length - startIndex;
        uint256 size = count == 0
            ? remaining
            : (count < remaining ? count : remaining);

        ids = new uint256[](size);
        users = new address[](size);
        requestTypes = new uint8[](size);
        statuses = new uint8[](size);
        tokenAddresses = new address[](size);
        amounts = new uint256[](size);
        yieldVaultIds = new uint64[](size);
        timestamps = new uint256[](size);
        messages = new string[](size);
        vaultIdentifiers = new string[](size);
        strategyIdentifiers = new string[](size);

        for (uint256 i = 0; i < size; ) {
            Request memory req = requests[pendingRequestIds[startIndex + i]];
            ids[i] = req.id;
            users[i] = req.user;
            requestTypes[i] = uint8(req.requestType);
            statuses[i] = uint8(req.status);
            tokenAddresses[i] = req.tokenAddress;
            amounts[i] = req.amount;
            yieldVaultIds[i] = req.yieldVaultId;
            timestamps[i] = req.timestamp;
            messages[i] = req.message;
            vaultIdentifiers[i] = req.vaultIdentifier;
            strategyIdentifiers[i] = req.strategyIdentifier;
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Gets a specific request by ID
    /// @param requestId Request ID
    /// @return Request data
    function getRequest(
        uint256 requestId
    ) external view returns (Request memory) {
        return requests[requestId];
    }

    /// @notice Gets a specific request by ID in unpacked format (tuple)
    /// @param requestId The request ID to fetch
    /// @return id Request id
    /// @return user User address
    /// @return requestType Request type
    /// @return status Request status
    /// @return tokenAddress Token address
    /// @return amount Amount
    /// @return yieldVaultId YieldVault Id
    /// @return timestamp Timestamp
    /// @return message Status message
    /// @return vaultIdentifier Vault identifier
    /// @return strategyIdentifier Strategy identifier
    function getRequestUnpacked(
        uint256 requestId
    )
        external
        view
        returns (
            uint256 id,
            address user,
            uint8 requestType,
            uint8 status,
            address tokenAddress,
            uint256 amount,
            uint64 yieldVaultId,
            uint256 timestamp,
            string memory message,
            string memory vaultIdentifier,
            string memory strategyIdentifier
        )
    {
        Request storage req = requests[requestId];
        id = req.id;
        user = req.user;
        requestType = uint8(req.requestType);
        status = uint8(req.status);
        tokenAddress = req.tokenAddress;
        amount = req.amount;
        yieldVaultId = req.yieldVaultId;
        timestamp = req.timestamp;
        message = req.message;
        vaultIdentifier = req.vaultIdentifier;
        strategyIdentifier = req.strategyIdentifier;
    }

    /// @notice Checks if a YieldVault Id is valid
    /// @param yieldVaultId YieldVault Id to check
    /// @return True if valid
    function isYieldVaultIdValid(
        uint64 yieldVaultId
    ) external view returns (bool) {
        return validYieldVaultIds[yieldVaultId];
    }

    /// @notice Gets a user's pending request count
    /// @param user User address
    /// @return Number of pending requests
    function getUserPendingRequestCount(
        address user
    ) external view returns (uint256) {
        return userPendingRequestCount[user];
    }

    /// @notice Gets all YieldVault Ids owned by a user
    /// @param user User address
    /// @return Array of YieldVault Ids
    function getYieldVaultIdsForUser(
        address user
    ) external view returns (uint64[] memory) {
        return yieldVaultsByUser[user];
    }

    /// @notice Checks if a user owns a specific YieldVault (O(1) lookup)
    /// @param user User address
    /// @param yieldVaultId YieldVault Id
    /// @return True if user owns the YieldVault
    function doesUserOwnYieldVault(
        address user,
        uint64 yieldVaultId
    ) external view returns (bool) {
        return userOwnsYieldVault[user][yieldVaultId];
    }

    /// @notice Gets pending requests for a specific user in unpacked format
    /// @dev Uses pendingRequestIdsByUser mapping for O(n) where n = user's pending requests (not all requests)
    /// @param user User address to filter by
    /// @return ids Request IDs
    /// @return requestTypes Request types
    /// @return statuses Request statuses
    /// @return tokenAddresses Token addresses
    /// @return amounts Amounts
    /// @return yieldVaultIds YieldVault Ids
    /// @return timestamps Timestamps
    /// @return messages Messages
    /// @return vaultIdentifiers Vault identifiers
    /// @return strategyIdentifiers Strategy identifiers
    /// @return balanceTokens Token addresses for balance arrays
    /// @return pendingBalances Escrowed balances for active pending requests per token
    /// @return claimableRefundsArray Claimable refund amounts per token
    function getPendingRequestsByUserUnpacked(
        address user
    )
        external
        view
        returns (
            uint256[] memory ids,
            uint8[] memory requestTypes,
            uint8[] memory statuses,
            address[] memory tokenAddresses,
            uint256[] memory amounts,
            uint64[] memory yieldVaultIds,
            uint256[] memory timestamps,
            string[] memory messages,
            string[] memory vaultIdentifiers,
            string[] memory strategyIdentifiers,
            address[] memory balanceTokens,
            uint256[] memory pendingBalances,
            uint256[] memory claimableRefundsArray
        )
    {
        // Use the user's pending request IDs directly (O(1) lookup)
        uint256[] storage userPendingIds = pendingRequestIdsByUser[user];
        uint256 count = userPendingIds.length;

        // Initialize arrays
        ids = new uint256[](count);
        requestTypes = new uint8[](count);
        statuses = new uint8[](count);
        tokenAddresses = new address[](count);
        amounts = new uint256[](count);
        yieldVaultIds = new uint64[](count);
        timestamps = new uint256[](count);
        messages = new string[](count);
        vaultIdentifiers = new string[](count);
        strategyIdentifiers = new string[](count);

        // Fill arrays - only iterate through user's requests
        for (uint256 i = 0; i < count; ) {
            Request storage req = requests[userPendingIds[i]];
            ids[i] = req.id;
            requestTypes[i] = uint8(req.requestType);
            statuses[i] = uint8(req.status);
            tokenAddresses[i] = req.tokenAddress;
            amounts[i] = req.amount;
            yieldVaultIds[i] = req.yieldVaultId;
            timestamps[i] = req.timestamp;
            messages[i] = req.message;
            vaultIdentifiers[i] = req.vaultIdentifier;
            strategyIdentifiers[i] = req.strategyIdentifier;
            unchecked {
                ++i;
            }
        }

        // Return balances for the full tracked token set so previously configured
        // tokens remain visible even if later disabled.
        uint256 tokenCount = _trackedTokens.length;
        balanceTokens = new address[](tokenCount);
        pendingBalances = new uint256[](tokenCount);
        claimableRefundsArray = new uint256[](tokenCount);

        for (uint256 i = 0; i < tokenCount; ) {
            address token = _trackedTokens[i];
            balanceTokens[i] = token;
            pendingBalances[i] = pendingUserBalances[user][token];
            claimableRefundsArray[i] = claimableRefunds[user][token];
            unchecked {
                ++i;
            }
        }
    }

    // ============================================
    // Internal Functions
    // ============================================

    /**
     * @dev Internal implementation for dropping pending requests.
     *      Silently skips requests that don't exist or aren't in PENDING status.
     *      For CREATE/DEPOSIT requests, escrowed funds are moved to claimableRefunds.
     * @param requestIds Array of request IDs to drop. Invalid/non-pending IDs are skipped.
     */
    function _dropRequestsInternal(uint256[] calldata requestIds) internal {
        // Pre-allocate array for tracking successfully dropped request IDs
        uint256[] memory droppedIds = new uint256[](requestIds.length);
        uint256 droppedCount = 0;

        // Process each request ID in the input array
        for (uint256 i = 0; i < requestIds.length; ) {
            uint256 requestId = requestIds[i];
            Request storage request = requests[requestId];

            // Only process valid requests that are still in PENDING status
            // This check prevents double-processing and handles invalid IDs gracefully
            if (
                request.id == requestId &&
                request.status == RequestStatus.PENDING
            ) {
                // Mark request as failed with admin message
                request.status = RequestStatus.FAILED;
                request.message = "Dropped";

                // For CREATE/DEPOSIT requests, move funds to claimableRefunds
                // User must call claimRefund() to withdraw them (pull pattern)
                // WITHDRAW/CLOSE requests don't escrow funds, so nothing to do
                if (
                    (request.requestType == RequestType.CREATE_YIELDVAULT ||
                        request.requestType == RequestType.DEPOSIT_TO_YIELDVAULT) &&
                    request.amount > 0
                ) {
                    uint256 newBalance =
                        pendingUserBalances[request.user][request.tokenAddress] -
                            request.amount;
                    pendingUserBalances[request.user][request.tokenAddress] = newBalance;
                    emit BalanceUpdated(
                        request.user,
                        request.tokenAddress,
                        newBalance
                    );
                    claimableRefunds[request.user][request.tokenAddress] += request.amount;
                    emit RefundCredited(
                        request.user,
                        request.tokenAddress,
                        request.amount,
                        requestId
                    );
                }

                // Update user's pending request count
                if (userPendingRequestCount[request.user] > 0) {
                    userPendingRequestCount[request.user]--;
                }

                // Remove from pending queues (both global and user-specific)
                _removePendingRequest(requestId);

                emit RequestProcessed(
                    requestId,
                    request.user,
                    request.requestType,
                    RequestStatus.FAILED,
                    request.yieldVaultId,
                    "Dropped"
                );

                // Track this request as successfully dropped
                droppedIds[droppedCount] = requestId;
                unchecked {
                    ++droppedCount;
                }
            }

            unchecked {
                ++i;
            }
        }

        // Emit batch event only if requests were actually dropped
        if (droppedCount > 0) {
            // Create properly-sized array for the event
            uint256[] memory actualDroppedIds = new uint256[](droppedCount);
            for (uint256 j = 0; j < droppedCount; ) {
                actualDroppedIds[j] = droppedIds[j];
                unchecked {
                    ++j;
                }
            }
            emit RequestsDropped(actualDroppedIds, msg.sender);
        }
    }

    /// @dev Stores token configuration and records tokens for future balance queries.
    function _setTokenConfig(
        address tokenAddress,
        bool isSupported,
        uint256 minimumBalance,
        bool isNative
    ) internal {
        if (isSupported && minimumBalance == 0) revert InvalidMinimumBalance();

        allowedTokens[tokenAddress] = TokenConfig({
            isSupported: isSupported,
            minimumBalance: minimumBalance,
            isNative: isNative
        });

        if (isSupported && !_isTrackedToken[tokenAddress]) {
            _isTrackedToken[tokenAddress] = true;
            _trackedTokens.push(tokenAddress);
        }
    }

    /**
     * @dev Internal implementation for starting request processing.
     *      Transitions request to PROCESSING status and handles fund transfers.
     * @param requestId The unique identifier of the request to start processing.
     */
    function _startProcessingInternal(uint256 requestId) internal {
        Request storage request = requests[requestId];

        // === VALIDATION ===
        if (request.id != requestId) revert RequestNotFound();
        if (request.status != RequestStatus.PENDING)
            revert InvalidRequestState();

        // === TRANSITION TO PROCESSING ===
        // This prevents cancellation and ensures atomicity with completeProcessing
        request.status = RequestStatus.PROCESSING;

        // === HANDLE FUND TRANSFER FOR CREATE/DEPOSIT ===
        // WITHDRAW/CLOSE don't have escrowed funds on EVM side
        if (
            request.requestType == RequestType.CREATE_YIELDVAULT ||
            request.requestType == RequestType.DEPOSIT_TO_YIELDVAULT
        ) {
            // Verify sufficient escrowed balance
            uint256 currentBalance = pendingUserBalances[request.user][
                request.tokenAddress
            ];
            if (currentBalance < request.amount) {
                revert InsufficientBalance(
                    request.tokenAddress,
                    request.amount,
                    currentBalance
                );
            }

            // Deduct from user's escrowed balance
            pendingUserBalances[request.user][request.tokenAddress] =
                currentBalance -
                request.amount;
            emit BalanceUpdated(
                request.user,
                request.tokenAddress,
                pendingUserBalances[request.user][request.tokenAddress]
            );

            // Transfer escrowed funds to COA for bridging to Cadence
            if (isNativeFlow(request.tokenAddress)) {
                // Native FLOW: send via low-level call
                (bool success, ) = authorizedCOA.call{value: request.amount}("");
                if (!success) revert TransferFailed();
            } else {
                // ERC20: use SafeERC20 transfer
                IERC20(request.tokenAddress).safeTransfer(
                    authorizedCOA,
                    request.amount
                );
                totalAccountedBalance[request.tokenAddress] -= request.amount;
            }
            emit FundsWithdrawn(
                authorizedCOA,
                request.tokenAddress,
                request.amount
            );
        }

        // === CLEANUP PENDING STATE ===
        if (userPendingRequestCount[request.user] > 0) {
            userPendingRequestCount[request.user]--;
        }
        _removePendingRequest(requestId);

        emit RequestProcessed(
            requestId,
            request.user,
            request.requestType,
            RequestStatus.PROCESSING,
            request.yieldVaultId,
            "Processing started"
        );
    }

    /**
     * @dev Validates deposit parameters and transfers tokens to this contract for escrow.
     *      Performs comprehensive validation including amount, token support, and minimum balance checks.
     *      For native FLOW, validates msg.value matches amount.
     *      For ERC20 tokens, pulls tokens from caller using safeTransferFrom (requires prior approval).
     * @param tokenAddress The token being deposited. Use NATIVE_FLOW sentinel for native $FLOW deposits.
     * @param amount The amount of tokens to deposit (in wei). Must be greater than zero and meet minimum requirements.
     */
    function _validateDeposit(address tokenAddress, uint256 amount) internal {
        // Validate amount is non-zero
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        // Load token configuration to check if supported and get requirements
        TokenConfig memory config = allowedTokens[tokenAddress];
        if (!config.isSupported) revert TokenNotSupported(tokenAddress);

        // Enforce minimum balance requirement if configured
        if (config.minimumBalance > 0 && amount < config.minimumBalance) {
            revert BelowMinimumBalance(
                tokenAddress,
                amount,
                config.minimumBalance
            );
        }

        // Handle token transfer based on token type
        if (config.isNative) {
            // Native FLOW: validate msg.value matches the deposit amount
            if (msg.value != amount) revert MsgValueMustEqualAmount();
        } else {
            // ERC20: ensure no native value sent, then pull tokens from caller
            if (msg.value != 0) revert MsgValueMustBeZero();
            IERC20(tokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                amount
            );
            totalAccountedBalance[tokenAddress] += amount;
        }
    }

    /**
     * @dev Validates that the specified user owns the given YieldVault.
     *      Checks both that the YieldVault exists (validYieldVaultIds) and that
     *      the user is the registered owner (yieldVaultOwners).
     * @param yieldVaultId The YieldVault Id to validate ownership for.
     * @param user The address that should own the YieldVault.
     */
    function _validateYieldVaultOwnership(
        uint64 yieldVaultId,
        address user
    ) internal view {
        // Check both validity and ownership in a single condition for gas efficiency
        if (
            !validYieldVaultIds[yieldVaultId] ||
            yieldVaultOwners[yieldVaultId] != user
        ) {
            revert InvalidYieldVaultId(yieldVaultId, user);
        }
    }

    /**
     * @dev Checks if the user has reached the maximum allowed pending requests.
     *      When maxPendingRequestsPerUser is 0, there is no limit.
     *      Reverts with TooManyPendingRequests if limit is reached.
     * @param user The address to check the pending request count for.
     */
    function _checkPendingRequestLimit(address user) internal view {
        // Skip check if limit is disabled (maxPendingRequestsPerUser == 0)
        if (
            maxPendingRequestsPerUser > 0 &&
            userPendingRequestCount[user] >= maxPendingRequestsPerUser
        ) {
            revert TooManyPendingRequests();
        }
    }

    /**
     * @dev Transfers funds to a recipient, handling both native $FLOW and ERC20 tokens.
     *      For native tokens, uses low-level call with value.
     *      For ERC20 tokens, uses SafeERC20's safeTransfer.
     * @param to The recipient address to transfer funds to.
     * @param tokenAddress The token to transfer. Use NATIVE_FLOW for native $FLOW.
     * @param amount The amount of tokens to transfer (in wei).
     */
    function _transferFunds(
        address to,
        address tokenAddress,
        uint256 amount
    ) internal {
        if (isNativeFlow(tokenAddress)) {
            // Native FLOW: use low-level call to transfer ETH/FLOW
            (bool success, ) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            // ERC20: use SafeERC20 for safe token transfer
            IERC20(tokenAddress).safeTransfer(to, amount);
            totalAccountedBalance[tokenAddress] -= amount;
        }
    }

    /**
     * @dev Registers a new YieldVault with comprehensive ownership tracking.
     *      Updates multiple mappings to enable O(1) lookups for:
     *      - Validity checks (validYieldVaultIds)
     *      - Owner lookups (yieldVaultOwners)
     *      - User's YieldVault list (yieldVaultsByUser)
     *      - Ownership verification (userOwnsYieldVault)
     *      Also tracks array index for O(1) removal when YieldVault is closed.
     * @param yieldVaultId The unique YieldVault Id assigned by the Cadence protocol.
     * @param user The address that will own this YieldVault.
     * @param tokenAddress The token address used to create this YieldVault.
     * @param requestId The CREATE_YIELDVAULT request ID that created this YieldVault.
     */
    function _registerYieldVault(
        uint64 yieldVaultId,
        address user,
        address tokenAddress,
        uint256 requestId
    ) internal {
        // Uniqueness guard, reject registering an already-valid yieldVaultId
        if (validYieldVaultIds[yieldVaultId]) {
            revert YieldVaultIdAlreadyRegistered(yieldVaultId);
        }
        // Reject sentinel value to prevent corruption of "no yieldvault" semantics
        if (yieldVaultId == NO_YIELDVAULT_ID) revert CannotRegisterSentinelYieldVaultId();

        // Mark YieldVault as valid and set owner
        validYieldVaultIds[yieldVaultId] = true;
        yieldVaultOwners[yieldVaultId] = user;
        yieldVaultTokens[yieldVaultId] = tokenAddress;

        // Track index in user's array for O(1) removal later
        _yieldVaultIndexInUserArray[user][yieldVaultId] = yieldVaultsByUser[user].length;
        yieldVaultsByUser[user].push(yieldVaultId);

        // Set ownership flag for O(1) ownership verification
        userOwnsYieldVault[user][yieldVaultId] = true;

        emit YieldVaultIdRegistered(yieldVaultId, user, requestId);
    }

    /**
     * @dev Unregisters a YieldVault and removes all ownership tracking.
     *      Uses swap-and-pop pattern for O(1) removal from user's YieldVault array.
     *      Order in yieldVaultsByUser doesn't affect protocol behavior, only enumeration.
     *      Cleans up all related mappings to properly invalidate the YieldVault.
     * @param yieldVaultId The YieldVault Id to unregister.
     * @param user The address that owns this YieldVault.
     * @param requestId The CLOSE_YIELDVAULT request ID that closed this YieldVault.
     */
    function _unregisterYieldVault(uint64 yieldVaultId, address user, uint256 requestId) internal {
        // Prove the yieldVaultId is actually registered under the provided user
        if (yieldVaultOwners[yieldVaultId] != user) {
            revert InvalidYieldVaultId(yieldVaultId, user);
        }

        uint64[] storage userYieldVaults = yieldVaultsByUser[user];
        uint256 indexToRemove = _yieldVaultIndexInUserArray[user][yieldVaultId];

        // Safety check: verify the element at index matches to prevent removing wrong YieldVault
        // This guards against index mapping corruption
        if (userYieldVaults.length > 0 && indexToRemove < userYieldVaults.length && userYieldVaults[indexToRemove] == yieldVaultId) {
            // Get the last element for swap-and-pop
            uint64 lastYieldVaultId = userYieldVaults[userYieldVaults.length - 1];

            // Move last element to the position being removed (skip if already last)
            if (indexToRemove != userYieldVaults.length - 1) {
                userYieldVaults[indexToRemove] = lastYieldVaultId;
                // Update index mapping for the moved element
                _yieldVaultIndexInUserArray[user][lastYieldVaultId] = indexToRemove;
            }

            // Pop the last element (now duplicated or the one to remove)
            userYieldVaults.pop();
            // Clean up index mapping for removed YieldVault
            delete _yieldVaultIndexInUserArray[user][yieldVaultId];
        }

        // Clear all ownership-related state
        userOwnsYieldVault[user][yieldVaultId] = false;
        validYieldVaultIds[yieldVaultId] = false;
        delete yieldVaultOwners[yieldVaultId];
        delete yieldVaultTokens[yieldVaultId];

        emit YieldVaultIdUnregistered(yieldVaultId, user, requestId);
    }

    /**
     * @dev Creates a new request and updates all related state.
     *      This function handles the core request creation logic shared by all request types:
     *      1. Generates unique request ID and stores request data
     *      2. Adds to global pending queue (FIFO order for processing)
     *      3. Adds to user's pending requests (for user-specific queries)
     *      4. Updates escrowed balance for CREATE/DEPOSIT requests
     *      5. Emits RequestCreated event for indexing
     * @param requestType The type of request (CREATE, DEPOSIT, WITHDRAW, CLOSE).
     * @param tokenAddress The token involved in this request.
     * @param amount The amount of tokens involved (0 for CLOSE requests).
     * @param yieldVaultId The YieldVault Id
     * @param vaultIdentifier Cadence vault type identifier (only for CREATE requests).
     * @param strategyIdentifier Cadence strategy type identifier (only for CREATE requests).
     * @return The newly created request ID.
     */
    function _createRequest(
        RequestType requestType,
        address tokenAddress,
        uint256 amount,
        uint64 yieldVaultId,
        string memory vaultIdentifier,
        string memory strategyIdentifier
    ) internal returns (uint256) {
        // Generate unique request ID using auto-incrementing counter
        uint256 requestId = _requestIdCounter++;

        // Store the complete request data
        requests[requestId] = Request({
            id: requestId,
            user: msg.sender,
            requestType: requestType,
            status: RequestStatus.PENDING,
            tokenAddress: tokenAddress,
            amount: amount,
            yieldVaultId: yieldVaultId,
            timestamp: block.timestamp,
            message: "",
            vaultIdentifier: vaultIdentifier,
            strategyIdentifier: strategyIdentifier
        });

        // Add to global pending queue with index tracking for O(1) lookup
        _requestIndexInGlobalArray[requestId] = pendingRequestIds.length;
        pendingRequestIds.push(requestId);
        userPendingRequestCount[msg.sender]++;

        // Add to user's pending array with index tracking for O(1) removal
        _requestIndexInUserArray[requestId] = pendingRequestIdsByUser[msg.sender].length;
        pendingRequestIdsByUser[msg.sender].push(requestId);

        // Update escrowed balance for requests that involve incoming funds
        if (
            requestType == RequestType.CREATE_YIELDVAULT ||
            requestType == RequestType.DEPOSIT_TO_YIELDVAULT
        ) {
            pendingUserBalances[msg.sender][tokenAddress] += amount;
            emit BalanceUpdated(
                msg.sender,
                tokenAddress,
                pendingUserBalances[msg.sender][tokenAddress]
            );
        }

        emit RequestCreated(
            requestId,
            msg.sender,
            requestType,
            tokenAddress,
            amount,
            yieldVaultId,
            block.timestamp,
            vaultIdentifier,
            strategyIdentifier
        );

        return requestId;
    }

    /**
     * @dev Removes a request from all pending queues while preserving request history.
     *      Uses two different removal strategies:
     *      - Global array: Shift elements to maintain FIFO order (O(n) but necessary for fair processing)
     *      - User array: Swap-and-pop for O(1) removal (order doesn't affect processing)
     *
     *      The request data remains in the `requests` mapping for historical queries;
     *      this function only removes it from the pending queues.
     * @param requestId The request ID to remove from pending queues.
     */
    function _removePendingRequest(uint256 requestId) internal {
        // === GLOBAL PENDING ARRAY REMOVAL ===
        // Uses O(1) lookup + O(n) shift to maintain FIFO order
        // FIFO order is critical for DeFi fairness - requests must be processed in submission order
        uint256 indexInGlobal = _requestIndexInGlobalArray[requestId];
        uint256 globalLength = pendingRequestIds.length;

        // Safety check: verify element exists at expected index
        if (globalLength > 0 && indexInGlobal < globalLength && pendingRequestIds[indexInGlobal] == requestId) {
            // Shift all subsequent elements left to maintain FIFO order
            for (uint256 j = indexInGlobal; j < globalLength - 1; ) {
                pendingRequestIds[j] = pendingRequestIds[j + 1];
                // Update index mapping for each shifted element
                _requestIndexInGlobalArray[pendingRequestIds[j]] = j;
                unchecked {
                    ++j;
                }
            }
            // Remove the last element (now duplicated or the one to remove)
            pendingRequestIds.pop();
            // Clean up index mapping
            delete _requestIndexInGlobalArray[requestId];
        }

        // === USER PENDING ARRAY REMOVAL ===
        // Uses swap-and-pop for O(1) removal (order doesn't affect FIFO processing)
        address user = requests[requestId].user;
        uint256[] storage userPendingIds = pendingRequestIdsByUser[user];
        uint256 indexToRemove = _requestIndexInUserArray[requestId];

        // IMPORTANT: Verify the element at index matches to prevent removing wrong request
        if (userPendingIds.length > 0 && indexToRemove < userPendingIds.length && userPendingIds[indexToRemove] == requestId) {
            // Get the last element
            uint256 lastRequestId = userPendingIds[userPendingIds.length - 1];

            // Move last element to the position being removed (if not already last)
            if (indexToRemove != userPendingIds.length - 1) {
                userPendingIds[indexToRemove] = lastRequestId;
                _requestIndexInUserArray[lastRequestId] = indexToRemove;
            }

            // Remove the last element
            userPendingIds.pop();
            delete _requestIndexInUserArray[requestId];
        }
    }
}
