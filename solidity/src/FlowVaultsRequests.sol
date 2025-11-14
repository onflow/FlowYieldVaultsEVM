// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

/**
 * @title FlowVaultsRequests
 * @notice Request queue and fund escrow for EVM users to interact with Flow Vaults Cadence protocol
 * @dev This contract holds user funds in escrow until processed by FlowVaultsEVM
 */
contract FlowVaultsRequests {
    // ============================================
    // Custom Errors
    // ============================================

    error NotAuthorizedCOA();
    error NotOwner();
    error NotInAllowlist();
    error InvalidCOAAddress();
    error EmptyAddressArray();
    error CannotAllowlistZeroAddress();
    error AmountMustBeGreaterThanZero();
    error MsgValueMustEqualAmount();
    error MsgValueMustBeZero();
    error ERC20NotSupported();
    error RequestNotFound();
    error NotRequestOwner();
    error CanOnlyCancelPending();
    error RequestAlreadyFinalized();
    error InsufficientBalance();
    error TransferFailed();

    // ============================================
    // Constants
    // ============================================

    /// @notice Special address representing native $FLOW (similar to 1inch approach)
    /// @dev Using recognizable pattern instead of address(0) for clarity
    address public constant NATIVE_FLOW =
        0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    // ============================================
    // Enums
    // ============================================

    enum RequestType {
        CREATE_TIDE,
        DEPOSIT_TO_TIDE,
        WITHDRAW_FROM_TIDE,
        CLOSE_TIDE
    }

    enum RequestStatus {
        PENDING,
        PROCESSING,
        COMPLETED,
        FAILED
    }

    // ============================================
    // Structs
    // ============================================

    struct Request {
        uint256 id;
        address user;
        RequestType requestType;
        RequestStatus status;
        address tokenAddress;
        uint256 amount;
        uint64 tideId; // Only used for DEPOSIT/WITHDRAW/CLOSE
        uint256 timestamp;
        string message; // Error message or status details
        string vaultIdentifier; // Cadence vault type identifier (e.g., "A.7e60df042a9c0868.FlowToken.Vault")
        string strategyIdentifier; // Cadence strategy type identifier (e.g., "A.3bda2f90274dbc9b.FlowVaultsStrategies.TracerStrategy")
    }

    // ============================================
    // State Variables
    // ============================================

    /// @notice Auto-incrementing request ID counter
    uint256 private _requestIdCounter;

    /// @notice Authorized COA address (controlled by FlowVaultsEVM)
    address public authorizedCOA;

    /// @notice Owner of the contract (for admin functions)
    address public owner;

    /// @notice Allow list enabled flag
    bool public allowlistEnabled;

    /// @notice Allow-listed addresses mapping
    mapping(address => bool) public allowlisted;

    /// @notice Pending user balances: user address => token address => balance
    /// @dev These are funds in escrow waiting to be converted to Tides
    mapping(address => mapping(address => uint256)) public pendingUserBalances;

    /// @notice Pending requests for efficient worker processing
    mapping(uint256 => Request) public pendingRequests;
    uint256[] public pendingRequestIds;

    // ============================================
    // Events
    // ============================================

    event RequestCreated(
        uint256 indexed requestId,
        address indexed user,
        RequestType requestType,
        address indexed tokenAddress,
        uint256 amount,
        uint64 tideId
    );

    event RequestProcessed(
        uint256 indexed requestId,
        RequestStatus status,
        uint64 tideId,
        string message
    );

    event RequestCancelled(
        uint256 indexed requestId,
        address indexed user,
        uint256 refundAmount
    );

    event BalanceUpdated(
        address indexed user,
        address indexed tokenAddress,
        uint256 newBalance
    );

    event FundsWithdrawn(
        address indexed to,
        address indexed tokenAddress,
        uint256 amount
    );

    event AuthorizedCOAUpdated(address indexed oldCOA, address indexed newCOA);

    event AllowlistEnabled(bool enabled);

    event AddressesAddedToAllowlist(address[] addresses);

    event AddressesRemovedFromAllowlist(address[] addresses);

    // ============================================
    // Modifiers
    // ============================================

    modifier onlyAuthorizedCOA() {
        if (msg.sender != authorizedCOA) revert NotAuthorizedCOA();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAllowlisted() {
        if (allowlistEnabled && !allowlisted[msg.sender])
            revert NotInAllowlist();
        _;
    }

    // ============================================
    // Constructor
    // ============================================

    constructor(address coaAddress) {
        owner = msg.sender;
        authorizedCOA = coaAddress;

        _requestIdCounter = 1;
    }

    // ============================================
    // Admin Functions
    // ============================================

    /// @notice Set the authorized COA address (can only be called by owner)
    /// @param _coa The COA address controlled by FlowVaultsEVM
    function setAuthorizedCOA(address _coa) external onlyOwner {
        if (_coa == address(0)) revert InvalidCOAAddress();
        address oldCOA = authorizedCOA;
        authorizedCOA = _coa;
        emit AuthorizedCOAUpdated(oldCOA, _coa);
    }

    /// @notice Enable or disable allow list enforcement
    /// @param _enabled True to enable allow list, false to disable
    function setAllowlistEnabled(bool _enabled) external onlyOwner {
        allowlistEnabled = _enabled;
        emit AllowlistEnabled(_enabled);
    }

    /// @notice Add multiple addresses to allow list
    /// @param _addresses Array of addresses to allow list
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

    /// @notice Remove multiple addresses from allow list
    /// @param _addresses Array of addresses to remove from allow list
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

    // ============================================
    // User Functions
    // ============================================

    /// @notice Create a new Tide (deposit funds to create position)
    /// @param tokenAddress Address of token (use NATIVE_FLOW for native $FLOW)
    /// @param amount Amount to deposit
    /// @param vaultIdentifier Cadence vault type identifier (e.g., "A.7e60df042a9c0868.FlowToken.Vault")
    /// @param strategyIdentifier Cadence strategy type identifier (e.g., "A.3bda2f90274dbc9b.FlowVaultsStrategies.TracerStrategy")
    function createTide(
        address tokenAddress,
        uint256 amount,
        string calldata vaultIdentifier,
        string calldata strategyIdentifier
    ) external payable onlyAllowlisted returns (uint256) {
        _validateDeposit(tokenAddress, amount);

        uint256 requestId = createRequest(
            RequestType.CREATE_TIDE,
            tokenAddress,
            amount,
            0, // No tideId yet
            vaultIdentifier,
            strategyIdentifier
        );

        return requestId;
    }

    /// @notice Deposit additional funds to existing Tide
    /// @param tideId The Tide ID to deposit to
    /// @param tokenAddress Address of token (use NATIVE_FLOW for native $FLOW)
    /// @param amount Amount to deposit
    function depositToTide(
        uint64 tideId,
        address tokenAddress,
        uint256 amount
    ) external payable onlyAllowlisted returns (uint256) {
        _validateDeposit(tokenAddress, amount);

        uint256 requestId = createRequest(
            RequestType.DEPOSIT_TO_TIDE,
            tokenAddress,
            amount,
            tideId,
            "", // No vault identifier needed for deposit
            "" // No strategy identifier needed for deposit
        );

        return requestId;
    }

    /// @notice Withdraw from existing Tide
    /// @param tideId The Tide ID to withdraw from
    /// @param amount Amount to withdraw
    function withdrawFromTide(
        uint64 tideId,
        uint256 amount
    ) external onlyAllowlisted returns (uint256) {
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        uint256 requestId = createRequest(
            RequestType.WITHDRAW_FROM_TIDE,
            NATIVE_FLOW, // Assume FLOW for MVP
            amount,
            tideId,
            "", // No vault identifier needed for withdraw
            "" // No strategy identifier needed for withdraw
        );

        return requestId;
    }

    /// @notice Close Tide and withdraw all funds
    /// @param tideId The Tide ID to close
    function closeTide(
        uint64 tideId
    ) external onlyAllowlisted returns (uint256) {
        uint256 requestId = createRequest(
            RequestType.CLOSE_TIDE,
            NATIVE_FLOW,
            0, // Amount will be determined by Cadence
            tideId,
            "", // No vault identifier needed for close
            "" // No strategy identifier needed for close
        );

        return requestId;
    }

    /// @notice Cancel a pending request and reclaim funds
    /// @param requestId The request ID to cancel
    function cancelRequest(uint256 requestId) external {
        Request storage request = pendingRequests[requestId];

        if (request.id != requestId) revert RequestNotFound();
        if (request.user != msg.sender) revert NotRequestOwner();
        if (request.status != RequestStatus.PENDING)
            revert CanOnlyCancelPending();

        // Update status to FAILED with cancellation message
        request.status = RequestStatus.FAILED;
        request.message = "Cancelled by user";

        // Remove from pending queue
        _removePendingRequest(requestId);

        // Refund funds if this was a CREATE_TIDE or DEPOSIT_TO_TIDE request
        uint256 refundAmount = 0;
        if (
            (request.requestType == RequestType.CREATE_TIDE ||
                request.requestType == RequestType.DEPOSIT_TO_TIDE) &&
            request.amount > 0
        ) {
            refundAmount = request.amount;

            // Decrease pending balance
            pendingUserBalances[msg.sender][request.tokenAddress] -= request
                .amount;
            emit BalanceUpdated(
                msg.sender,
                request.tokenAddress,
                pendingUserBalances[msg.sender][request.tokenAddress]
            );

            // Refund the funds
            if (isNativeFlow(request.tokenAddress)) {
                (bool success, ) = msg.sender.call{value: request.amount}("");
                if (!success) revert TransferFailed();
            } else {
                // TODO: Transfer ERC20 tokens (Phase 2)
                revert ERC20NotSupported();
            }

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
    // COA Functions (called by FlowVaultsEVM)
    // ============================================

    /// @notice Withdraw funds from contract (only authorized COA)
    /// @param tokenAddress Token to withdraw
    /// @param amount Amount to withdraw
    function withdrawFunds(
        address tokenAddress,
        uint256 amount
    ) external onlyAuthorizedCOA {
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        if (isNativeFlow(tokenAddress)) {
            if (address(this).balance < amount) revert InsufficientBalance();
            (bool success, ) = msg.sender.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            // TODO: Transfer ERC20 tokens (Phase 2)
            revert ERC20NotSupported();
        }

        emit FundsWithdrawn(msg.sender, tokenAddress, amount);
    }

    /// @notice Update request status (only authorized COA)
    /// @param requestId Request ID to update
    /// @param status New status (as uint8: 0=PENDING, 1=PROCESSING, 2=COMPLETED, 3=FAILED)
    /// @param tideId Associated Tide ID (if applicable)
    /// @param message Status message (e.g., error reason if failed)
    function updateRequestStatus(
        uint256 requestId,
        uint8 status,
        uint64 tideId,
        string calldata message
    ) external onlyAuthorizedCOA {
        Request storage request = pendingRequests[requestId];
        if (request.id != requestId) revert RequestNotFound();
        if (
            request.status != RequestStatus.PENDING &&
            request.status != RequestStatus.PROCESSING
        ) revert RequestAlreadyFinalized();

        // Convert uint8 to RequestStatus
        request.status = RequestStatus(status);
        request.message = message;
        if (tideId > 0) {
            request.tideId = tideId;
        }

        // If completed or failed, remove from pending queue
        if (
            status == uint8(RequestStatus.COMPLETED) ||
            status == uint8(RequestStatus.FAILED)
        ) {
            _removePendingRequest(requestId);
        }

        emit RequestProcessed(
            requestId,
            RequestStatus(status),
            tideId,
            message
        );
    }

    /// @notice Update user balance (only authorized COA)
    /// @param user User address
    /// @param tokenAddress Token address
    /// @param newBalance New balance
    function updateUserBalance(
        address user,
        address tokenAddress,
        uint256 newBalance
    ) external onlyAuthorizedCOA {
        pendingUserBalances[user][tokenAddress] = newBalance;
        emit BalanceUpdated(user, tokenAddress, newBalance);
    }

    // ============================================
    // View Functions
    // ============================================

    /// @notice Check if token is native FLOW
    function isNativeFlow(address tokenAddress) public pure returns (bool) {
        return tokenAddress == NATIVE_FLOW;
    }

    /// @notice Get user's pending balance for a token
    function getUserBalance(
        address user,
        address tokenAddress
    ) external view returns (uint256) {
        return pendingUserBalances[user][tokenAddress];
    }

    /// @notice Get count of pending requests (most gas-efficient)
    function getPendingRequestCount() external view returns (uint256) {
        return pendingRequestIds.length;
    }

    /// @notice Get all pending request IDs (for counting/scheduling)
    function getPendingRequestIds() external view returns (uint256[] memory) {
        return pendingRequestIds;
    }

    /// @notice Get pending requests unpacked with limit (OPTIMIZED for Cadence)
    /// @param limit Maximum number of requests to return (0 = return all)
    /// @return ids Array of request IDs
    /// @return users Array of user addresses
    /// @return requestTypes Array of request types
    /// @return statuses Array of request statuses
    /// @return tokenAddresses Array of token addresses
    /// @return amounts Array of amounts
    /// @return tideIds Array of tide IDs
    /// @return timestamps Array of timestamps
    /// @return messages Array of status messages
    /// @return vaultIdentifiers Array of vault identifiers
    /// @return strategyIdentifiers Array of strategy identifiers
    function getPendingRequestsUnpacked(
        uint256 limit
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
        // Determine actual size: min(limit, total pending)
        // If limit is 0, return all requests
        uint256 size = limit == 0
            ? pendingRequestIds.length
            : (
                limit < pendingRequestIds.length
                    ? limit
                    : pendingRequestIds.length
            );

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

        // Populate arrays up to size
        for (uint256 i = 0; i < size; ) {
            Request memory req = pendingRequests[pendingRequestIds[i]];
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

    /// @notice Get specific request
    function getRequest(
        uint256 requestId
    ) external view returns (Request memory) {
        return pendingRequests[requestId];
    }

    // ============================================
    // Internal Functions
    // ============================================

    /// @notice Validate token deposit (amount and msg.value)
    /// @param tokenAddress Token being deposited
    /// @param amount Amount being deposited
    function _validateDeposit(
        address tokenAddress,
        uint256 amount
    ) internal view {
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        if (isNativeFlow(tokenAddress)) {
            if (msg.value != amount) revert MsgValueMustEqualAmount();
        } else {
            if (msg.value != 0) revert MsgValueMustBeZero();
            // TODO: Transfer ERC20 tokens (Phase 2)
            revert ERC20NotSupported();
        }
    }

    function createRequest(
        RequestType requestType,
        address tokenAddress,
        uint256 amount,
        uint64 tideId,
        string memory vaultIdentifier,
        string memory strategyIdentifier
    ) internal returns (uint256) {
        address user = msg.sender;
        uint256 requestId = _requestIdCounter++;

        Request memory newRequest = Request({
            id: requestId,
            user: user,
            requestType: requestType,
            status: RequestStatus.PENDING,
            tokenAddress: tokenAddress,
            amount: amount,
            tideId: tideId,
            timestamp: block.timestamp,
            message: "", // Empty message initially
            vaultIdentifier: vaultIdentifier,
            strategyIdentifier: strategyIdentifier
        });

        // Store in pending requests
        pendingRequests[requestId] = newRequest;
        pendingRequestIds.push(requestId);

        // Update pending user balance if depositing
        if (
            requestType == RequestType.CREATE_TIDE ||
            requestType == RequestType.DEPOSIT_TO_TIDE
        ) {
            pendingUserBalances[user][tokenAddress] += amount;
            emit BalanceUpdated(
                user,
                tokenAddress,
                pendingUserBalances[user][tokenAddress]
            );
        }

        emit RequestCreated(
            requestId,
            user,
            requestType,
            tokenAddress,
            amount,
            tideId
        );

        return requestId;
    }

    function _removePendingRequest(uint256 requestId) internal {
        // Find and remove from pendingRequestIds array
        for (uint256 i = 0; i < pendingRequestIds.length; ) {
            if (pendingRequestIds[i] == requestId) {
                // Move last element to this position and pop
                pendingRequestIds[i] = pendingRequestIds[
                    pendingRequestIds.length - 1
                ];
                pendingRequestIds.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }

        // Don't delete from pendingRequests mapping to preserve history
        // Just mark as completed/failed via status
    }

    // ============================================
    // Receive Function
    // ============================================

    receive() external payable {
        // Allow contract to receive ETH
    }
}
