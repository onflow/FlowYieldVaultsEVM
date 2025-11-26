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
 * @title FlowVaultsRequests
 * @author Flow Vaults Team
 * @notice Request queue and fund escrow for EVM users to interact with Flow Vaults Cadence protocol
 * @dev This contract serves as an escrow and request queue for cross-VM operations between
 *      EVM and Cadence. Users deposit funds here, and the authorized COA (Cadence Owned Account)
 *      processes requests by bridging funds to Cadence and executing Flow Vaults operations.
 *
 *      Key flows:
 *      1. CREATE_TIDE: User deposits funds → COA bridges to Cadence → Tide created
 *      2. DEPOSIT_TO_TIDE: User deposits funds → COA bridges to existing Tide
 *      3. WITHDRAW_FROM_TIDE: User requests withdrawal → COA bridges funds back
 *      4. CLOSE_TIDE: User requests closure → COA closes Tide and bridges all funds back
 *
 *      Processing uses atomic two-phase commit:
 *      - startProcessing(): Marks request as PROCESSING, deducts user balance
 *      - completeProcessing(): Marks as COMPLETED/FAILED, refunds on failure
 */
contract FlowVaultsRequests is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ============================================
    // Type Declarations
    // ============================================

    /// @notice Types of requests that can be made to the Flow Vaults protocol
    enum RequestType {
        CREATE_TIDE,
        DEPOSIT_TO_TIDE,
        WITHDRAW_FROM_TIDE,
        CLOSE_TIDE
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
    /// @param tideId Associated Tide ID (NO_TIDE_ID for CREATE_TIDE until completed)
    /// @param timestamp Block timestamp when request was created
    /// @param message Status message or error reason
    /// @param vaultIdentifier Cadence vault type identifier for CREATE_TIDE
    /// @param strategyIdentifier Cadence strategy type identifier for CREATE_TIDE
    struct Request {
        uint256 id;
        address user;
        RequestType requestType;
        RequestStatus status;
        address tokenAddress;
        uint256 amount;
        uint64 tideId;
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

    /// @notice Sentinel value for "no tide" (used when CREATE_TIDE fails before tide is created)
    /// @dev Uses type(uint64).max since valid tideIds can be 0. Matches FlowVaultsEVM.noTideId
    uint64 public constant NO_TIDE_ID = type(uint64).max;

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

    /// @notice Addresses blocked from creating requests
    mapping(address => bool) public blocklisted;

    /// @notice Token configurations indexed by token address
    mapping(address => TokenConfig) public allowedTokens;

    /// @notice Maximum number of pending requests allowed per user (0 = unlimited)
    uint256 public maxPendingRequestsPerUser;

    /// @notice Count of pending requests per user
    mapping(address => uint256) public userPendingRequestCount;

    /// @notice Registry of valid Tide IDs created through this contract
    mapping(uint64 => bool) public validTideIds;

    /// @notice Owner address for each Tide ID
    mapping(uint64 => address) public tideOwners;

    /// @notice Array of Tide IDs owned by each user
    mapping(address => uint64[]) public tidesByUser;

    /// @notice O(1) lookup for tide ownership verification
    mapping(address => mapping(uint64 => bool)) public userOwnsTide;

    /// @notice Escrowed balances: user => token => amount
    mapping(address => mapping(address => uint256)) public pendingUserBalances;

    /// @notice All requests indexed by request ID
    mapping(uint256 => Request) public requests;

    /// @notice Array of pending request IDs awaiting processing
    uint256[] public pendingRequestIds;

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

    /// @notice Address array cannot be empty
    error EmptyAddressArray();

    /// @notice Cannot add zero address to allowlist
    error CannotAllowlistZeroAddress();

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
    error RequestAlreadyFinalized();

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

    /// @notice Tide ID is invalid or not owned by user
    error InvalidTideId(uint64 tideId, address user);

    // ============================================
    // Events
    // ============================================

    /// @notice Emitted when a new request is created
    /// @param requestId Unique identifier for the request
    /// @param user Address of the user who created the request
    /// @param requestType Type of operation requested
    /// @param tokenAddress Token involved in the request
    /// @param amount Amount of tokens
    /// @param tideId Associated Tide ID (0 for new tides)
    event RequestCreated(
        uint256 indexed requestId,
        address indexed user,
        RequestType requestType,
        address indexed tokenAddress,
        uint256 amount,
        uint64 tideId
    );

    /// @notice Emitted when a request status changes
    /// @param requestId Request being updated
    /// @param status New status
    /// @param tideId Associated Tide ID
    /// @param message Status message or error reason
    event RequestProcessed(
        uint256 indexed requestId,
        RequestStatus status,
        uint64 tideId,
        string message
    );

    /// @notice Emitted when a user cancels their request
    /// @param requestId Cancelled request ID
    /// @param user User who cancelled
    /// @param refundAmount Amount refunded to user
    event RequestCancelled(
        uint256 indexed requestId,
        address indexed user,
        uint256 refundAmount
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
    event AllowlistEnabled(bool enabled);

    /// @notice Emitted when addresses are added to allowlist
    /// @param addresses Addresses added
    event AddressesAddedToAllowlist(address[] addresses);

    /// @notice Emitted when addresses are removed from allowlist
    /// @param addresses Addresses removed
    event AddressesRemovedFromAllowlist(address[] addresses);

    /// @notice Emitted when blocklist status changes
    /// @param enabled New status
    event BlocklistEnabled(bool enabled);

    /// @notice Emitted when addresses are added to blocklist
    /// @param addresses Addresses added
    event AddressesAddedToBlocklist(address[] addresses);

    /// @notice Emitted when addresses are removed from blocklist
    /// @param addresses Addresses removed
    event AddressesRemovedFromBlocklist(address[] addresses);

    /// @notice Emitted when token configuration changes
    /// @param token Token address
    /// @param isSupported Whether token is supported
    /// @param minimumBalance Minimum deposit amount
    /// @param isNative Whether token is native $FLOW
    event TokenConfigured(
        address indexed token,
        bool isSupported,
        uint256 minimumBalance,
        bool isNative
    );

    /// @notice Emitted when max pending requests limit changes
    /// @param oldMax Previous limit
    /// @param newMax New limit
    event MaxPendingRequestsPerUserUpdated(uint256 oldMax, uint256 newMax);

    /// @notice Emitted when a new Tide is registered
    /// @param tideId Newly registered Tide ID
    event TideIdRegistered(uint64 indexed tideId);

    /// @notice Emitted when requests are dropped by admin
    /// @param requestIds Dropped request IDs
    /// @param droppedBy Admin who dropped the requests
    event RequestsDropped(uint256[] requestIds, address indexed droppedBy);

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

    // ============================================
    // Constructor
    // ============================================

    /// @notice Initializes the contract with COA address and default configuration
    /// @param coaAddress Address of the authorized COA
    constructor(address coaAddress) Ownable(msg.sender) {
        authorizedCOA = coaAddress;
        _requestIdCounter = 1;
        maxPendingRequestsPerUser = 10;

        allowedTokens[NATIVE_FLOW] = TokenConfig({
            isSupported: true,
            minimumBalance: 1 ether,
            isNative: true
        });
    }

    // ============================================
    // Receive Function
    // ============================================

    /// @notice Allows contract to receive native $FLOW
    receive() external payable {}

    // ============================================
    // External Functions - Admin
    // ============================================

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
        emit AllowlistEnabled(_enabled);
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

        emit AddressesAddedToAllowlist(_addresses);
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

        emit AddressesRemovedFromAllowlist(_addresses);
    }

    /// @notice Enables or disables blocklist enforcement
    /// @param _enabled True to enable, false to disable
    function setBlocklistEnabled(bool _enabled) external onlyOwner {
        blocklistEnabled = _enabled;
        emit BlocklistEnabled(_enabled);
    }

    /// @notice Adds multiple addresses to the blocklist
    /// @param _addresses Addresses to add
    function batchAddToBlocklist(
        address[] calldata _addresses
    ) external onlyOwner {
        if (_addresses.length == 0) revert EmptyAddressArray();

        for (uint256 i = 0; i < _addresses.length; ) {
            if (_addresses[i] == address(0))
                revert CannotAllowlistZeroAddress();
            blocklisted[_addresses[i]] = true;
            unchecked {
                ++i;
            }
        }

        emit AddressesAddedToBlocklist(_addresses);
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

        emit AddressesRemovedFromBlocklist(_addresses);
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
        allowedTokens[tokenAddress] = TokenConfig({
            isSupported: isSupported,
            minimumBalance: minimumBalance,
            isNative: isNative
        });

        emit TokenConfigured(
            tokenAddress,
            isSupported,
            minimumBalance,
            isNative
        );
    }

    /// @notice Sets the maximum pending requests allowed per user
    /// @param _maxRequests New limit (0 = unlimited)
    function setMaxPendingRequestsPerUser(
        uint256 _maxRequests
    ) external onlyOwner {
        uint256 oldMax = maxPendingRequestsPerUser;
        maxPendingRequestsPerUser = _maxRequests;
        emit MaxPendingRequestsPerUserUpdated(oldMax, _maxRequests);
    }

    /// @notice Drops pending requests and refunds users (admin cleanup function)
    /// @param requestIds Request IDs to drop
    function dropRequests(
        uint256[] calldata requestIds
    ) external onlyOwner nonReentrant {
        for (uint256 i = 0; i < requestIds.length; ) {
            uint256 requestId = requestIds[i];
            Request storage request = requests[requestId];

            if (
                request.id == requestId &&
                request.status == RequestStatus.PENDING
            ) {
                request.status = RequestStatus.FAILED;
                request.message = "Dropped by admin";

                if (
                    (request.requestType == RequestType.CREATE_TIDE ||
                        request.requestType == RequestType.DEPOSIT_TO_TIDE) &&
                    request.amount > 0
                ) {
                    pendingUserBalances[request.user][
                        request.tokenAddress
                    ] -= request.amount;
                    emit BalanceUpdated(
                        request.user,
                        request.tokenAddress,
                        pendingUserBalances[request.user][request.tokenAddress]
                    );

                    _transferFunds(
                        request.user,
                        request.tokenAddress,
                        request.amount
                    );

                    emit FundsWithdrawn(
                        request.user,
                        request.tokenAddress,
                        request.amount
                    );
                }

                if (userPendingRequestCount[request.user] > 0) {
                    userPendingRequestCount[request.user]--;
                }

                _removePendingRequest(requestId);

                emit RequestProcessed(
                    requestId,
                    RequestStatus.FAILED,
                    request.tideId,
                    "Dropped by admin"
                );
            }

            unchecked {
                ++i;
            }
        }

        emit RequestsDropped(requestIds, msg.sender);
    }

    // ============================================
    // External Functions - User
    // ============================================

    /// @notice Creates a new Tide by depositing funds
    /// @param tokenAddress Token to deposit (use NATIVE_FLOW for native $FLOW)
    /// @param amount Amount to deposit
    /// @param vaultIdentifier Cadence vault type identifier
    /// @param strategyIdentifier Cadence strategy type identifier
    /// @return requestId The created request ID
    function createTide(
        address tokenAddress,
        uint256 amount,
        string calldata vaultIdentifier,
        string calldata strategyIdentifier
    )
        external
        payable
        onlyAllowlisted
        notBlocklisted
        nonReentrant
        returns (uint256)
    {
        _validateDeposit(tokenAddress, amount);
        _checkPendingRequestLimit(msg.sender);

        return
            _createRequest(
                RequestType.CREATE_TIDE,
                tokenAddress,
                amount,
                0,
                vaultIdentifier,
                strategyIdentifier
            );
    }

    /// @notice Deposits additional funds to an existing Tide
    /// @param tideId Tide ID to deposit to
    /// @param tokenAddress Token to deposit
    /// @param amount Amount to deposit
    /// @return requestId The created request ID
    function depositToTide(
        uint64 tideId,
        address tokenAddress,
        uint256 amount
    )
        external
        payable
        onlyAllowlisted
        notBlocklisted
        nonReentrant
        returns (uint256)
    {
        _validateDeposit(tokenAddress, amount);
        _validateTideOwnership(tideId, msg.sender);
        _checkPendingRequestLimit(msg.sender);

        return
            _createRequest(
                RequestType.DEPOSIT_TO_TIDE,
                tokenAddress,
                amount,
                tideId,
                "",
                ""
            );
    }

    /// @notice Requests a withdrawal from an existing Tide
    /// @param tideId Tide ID to withdraw from
    /// @param amount Amount to withdraw
    /// @return requestId The created request ID
    function withdrawFromTide(
        uint64 tideId,
        uint256 amount
    ) external onlyAllowlisted notBlocklisted returns (uint256) {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        _validateTideOwnership(tideId, msg.sender);
        _checkPendingRequestLimit(msg.sender);

        return
            _createRequest(
                RequestType.WITHDRAW_FROM_TIDE,
                NATIVE_FLOW,
                amount,
                tideId,
                "",
                ""
            );
    }

    /// @notice Requests closure of a Tide and withdrawal of all funds
    /// @param tideId Tide ID to close
    /// @return requestId The created request ID
    function closeTide(
        uint64 tideId
    ) external onlyAllowlisted notBlocklisted returns (uint256) {
        _validateTideOwnership(tideId, msg.sender);
        _checkPendingRequestLimit(msg.sender);

        return
            _createRequest(
                RequestType.CLOSE_TIDE,
                NATIVE_FLOW,
                0,
                tideId,
                "",
                ""
            );
    }

    /// @notice Cancels a pending request and refunds deposited funds
    /// @param requestId Request ID to cancel
    function cancelRequest(uint256 requestId) external nonReentrant {
        Request storage request = requests[requestId];

        if (request.id != requestId) revert RequestNotFound();
        if (request.user != msg.sender) revert NotRequestOwner();
        if (request.status != RequestStatus.PENDING)
            revert CanOnlyCancelPending();

        request.status = RequestStatus.FAILED;
        request.message = "Cancelled by user";

        if (userPendingRequestCount[msg.sender] > 0) {
            userPendingRequestCount[msg.sender]--;
        }

        _removePendingRequest(requestId);

        uint256 refundAmount = 0;
        if (
            (request.requestType == RequestType.CREATE_TIDE ||
                request.requestType == RequestType.DEPOSIT_TO_TIDE) &&
            request.amount > 0
        ) {
            refundAmount = request.amount;
            pendingUserBalances[msg.sender][request.tokenAddress] -= request
                .amount;
            emit BalanceUpdated(
                msg.sender,
                request.tokenAddress,
                pendingUserBalances[msg.sender][request.tokenAddress]
            );

            _transferFunds(msg.sender, request.tokenAddress, request.amount);

            emit FundsWithdrawn(
                msg.sender,
                request.tokenAddress,
                request.amount
            );
        }

        emit RequestCancelled(requestId, msg.sender, refundAmount);
        emit RequestProcessed(
            requestId,
            RequestStatus.FAILED,
            request.tideId,
            "Cancelled by user"
        );
    }

    // ============================================
    // External Functions - COA
    // ============================================

    /// @notice Begins processing a request (atomically deducts user balance)
    /// @dev Must be called before Cadence-side operations. Deducts balance to prevent double-spend.
    /// @param requestId Request ID to start processing
    function startProcessing(uint256 requestId) external onlyAuthorizedCOA {
        Request storage request = requests[requestId];
        if (request.id != requestId) revert RequestNotFound();
        if (request.status != RequestStatus.PENDING)
            revert RequestAlreadyFinalized();

        request.status = RequestStatus.PROCESSING;

        if (
            request.requestType == RequestType.CREATE_TIDE ||
            request.requestType == RequestType.DEPOSIT_TO_TIDE
        ) {
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
            pendingUserBalances[request.user][request.tokenAddress] =
                currentBalance -
                request.amount;
        }

        emit RequestProcessed(
            requestId,
            RequestStatus.PROCESSING,
            request.tideId,
            "Processing started"
        );
    }

    /// @notice Completes request processing (marks success/failure, handles refunds)
    /// @dev Called after Cadence-side operations complete. Refunds user balance on failure.
    /// @param requestId Request ID to complete
    /// @param success Whether the Cadence operation succeeded
    /// @param tideId Tide ID associated with the request
    /// @param message Status message or error description
    function completeProcessing(
        uint256 requestId,
        bool success,
        uint64 tideId,
        string calldata message
    ) external onlyAuthorizedCOA {
        Request storage request = requests[requestId];
        if (request.id != requestId) revert RequestNotFound();
        if (request.status != RequestStatus.PROCESSING)
            revert RequestAlreadyFinalized();

        RequestStatus newStatus = success
            ? RequestStatus.COMPLETED
            : RequestStatus.FAILED;
        request.status = newStatus;
        request.message = message;
        request.tideId = tideId;

        if (
            !success &&
            (request.requestType == RequestType.CREATE_TIDE ||
                request.requestType == RequestType.DEPOSIT_TO_TIDE)
        ) {
            pendingUserBalances[request.user][request.tokenAddress] += request
                .amount;
        }

        if (success && request.requestType == RequestType.CREATE_TIDE) {
            _registerTide(tideId, request.user);
        }

        if (success && request.requestType == RequestType.CLOSE_TIDE) {
            _unregisterTide(tideId, request.user);
        }

        if (userPendingRequestCount[request.user] > 0) {
            userPendingRequestCount[request.user]--;
        }
        _removePendingRequest(requestId);

        emit RequestProcessed(requestId, newStatus, tideId, message);
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

    /// @notice Gets a user's escrowed balance for a token
    /// @param user User address
    /// @param tokenAddress Token address
    /// @return Escrowed balance
    function getUserPendingBalance(
        address user,
        address tokenAddress
    ) external view returns (uint256) {
        return pendingUserBalances[user][tokenAddress];
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
    /// @return tideIds Tide IDs
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
            uint64[] memory tideIds,
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
        tideIds = new uint64[](size);
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
            tideIds[i] = req.tideId;
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

    /// @notice Checks if a Tide ID is valid
    /// @param tideId Tide ID to check
    /// @return True if valid
    function isTideIdValid(uint64 tideId) external view returns (bool) {
        return validTideIds[tideId];
    }

    /// @notice Gets a user's pending request count
    /// @param user User address
    /// @return Number of pending requests
    function getUserPendingRequestCount(
        address user
    ) external view returns (uint256) {
        return userPendingRequestCount[user];
    }

    /// @notice Gets all Tide IDs owned by a user
    /// @param user User address
    /// @return Array of Tide IDs
    function getTideIDsForUser(
        address user
    ) external view returns (uint64[] memory) {
        return tidesByUser[user];
    }

    /// @notice Checks if a user owns a specific Tide (O(1) lookup)
    /// @param user User address
    /// @param tideId Tide ID
    /// @return True if user owns the Tide
    function doesUserOwnTide(
        address user,
        uint64 tideId
    ) external view returns (bool) {
        return userOwnsTide[user][tideId];
    }

    // ============================================
    // Internal Functions
    // ============================================

    /// @dev Validates deposit parameters and transfers tokens
    function _validateDeposit(address tokenAddress, uint256 amount) internal {
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        TokenConfig memory config = allowedTokens[tokenAddress];
        if (!config.isSupported) revert TokenNotSupported(tokenAddress);

        if (config.minimumBalance > 0 && amount < config.minimumBalance) {
            revert BelowMinimumBalance(
                tokenAddress,
                amount,
                config.minimumBalance
            );
        }

        if (config.isNative) {
            if (msg.value != amount) revert MsgValueMustEqualAmount();
        } else {
            if (msg.value != 0) revert MsgValueMustBeZero();
            IERC20(tokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                amount
            );
        }
    }

    /// @dev Validates that user owns the specified Tide
    function _validateTideOwnership(uint64 tideId, address user) internal view {
        if (!validTideIds[tideId] || tideOwners[tideId] != user) {
            revert InvalidTideId(tideId, user);
        }
    }

    /// @dev Checks if user has reached pending request limit
    function _checkPendingRequestLimit(address user) internal view {
        if (
            maxPendingRequestsPerUser > 0 &&
            userPendingRequestCount[user] >= maxPendingRequestsPerUser
        ) {
            revert TooManyPendingRequests();
        }
    }

    /// @dev Checks if token is native $FLOW
    function _isNativeToken(address tokenAddress) internal view returns (bool) {
        return allowedTokens[tokenAddress].isNative;
    }

    /// @dev Transfers funds to recipient (native or ERC20)
    function _transferFunds(
        address to,
        address tokenAddress,
        uint256 amount
    ) internal {
        if (_isNativeToken(tokenAddress)) {
            (bool success, ) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(tokenAddress).safeTransfer(to, amount);
        }
    }

    /// @dev Registers a new Tide with ownership tracking
    function _registerTide(uint64 tideId, address user) internal {
        validTideIds[tideId] = true;
        tideOwners[tideId] = user;
        tidesByUser[user].push(tideId);
        userOwnsTide[user][tideId] = true;
        emit TideIdRegistered(tideId);
    }

    /// @dev Unregisters a Tide and removes ownership tracking
    function _unregisterTide(uint64 tideId, address user) internal {
        uint64[] storage userTides = tidesByUser[user];
        for (uint256 i = 0; i < userTides.length; ) {
            if (userTides[i] == tideId) {
                userTides[i] = userTides[userTides.length - 1];
                userTides.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }

        userOwnsTide[user][tideId] = false;
        validTideIds[tideId] = false;
        delete tideOwners[tideId];
    }

    /// @dev Creates a new request and updates state
    function _createRequest(
        RequestType requestType,
        address tokenAddress,
        uint256 amount,
        uint64 tideId,
        string memory vaultIdentifier,
        string memory strategyIdentifier
    ) internal returns (uint256) {
        uint256 requestId = _requestIdCounter++;

        requests[requestId] = Request({
            id: requestId,
            user: msg.sender,
            requestType: requestType,
            status: RequestStatus.PENDING,
            tokenAddress: tokenAddress,
            amount: amount,
            tideId: tideId,
            timestamp: block.timestamp,
            message: "",
            vaultIdentifier: vaultIdentifier,
            strategyIdentifier: strategyIdentifier
        });

        pendingRequestIds.push(requestId);
        userPendingRequestCount[msg.sender]++;

        if (
            requestType == RequestType.CREATE_TIDE ||
            requestType == RequestType.DEPOSIT_TO_TIDE
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
            tideId
        );

        return requestId;
    }

    /// @dev Removes a request from the pending queue (preserves history in requests mapping)
    function _removePendingRequest(uint256 requestId) internal {
        for (uint256 i = 0; i < pendingRequestIds.length; ) {
            if (pendingRequestIds[i] == requestId) {
                for (uint256 j = i; j < pendingRequestIds.length - 1; ) {
                    pendingRequestIds[j] = pendingRequestIds[j + 1];
                    unchecked {
                        ++j;
                    }
                }
                pendingRequestIds.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
    }
}
