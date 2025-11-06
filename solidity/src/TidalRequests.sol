// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

/**
 * @title TidalRequests
 * @notice Request queue and fund escrow for EVM users to interact with Tidal Cadence protocol
 * @dev This contract holds user funds in escrow until processed by TidalEVM
 */
contract TidalRequests {
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
    }

    // ============================================
    // State Variables
    // ============================================

    /// @notice Auto-incrementing request ID counter
    uint256 private _requestIdCounter;

    /// @notice Authorized COA address (controlled by TidalEVM)
    address public authorizedCOA;

    /// @notice Owner of the contract (for admin functions)
    address public owner;

    /// @notice User request history: user address => array of requests
    mapping(address => Request[]) public userRequests;

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

    // ============================================
    // Modifiers
    // ============================================

    modifier onlyAuthorizedCOA() {
        require(
            msg.sender == authorizedCOA,
            "TidalRequests: caller is not authorized COA"
        );
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "TidalRequests: caller is not owner");
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
    /// @param _coa The COA address controlled by TidalEVM
    function setAuthorizedCOA(address _coa) external onlyOwner {
        require(_coa != address(0), "TidalRequests: invalid COA address");
        address oldCOA = authorizedCOA;
        authorizedCOA = _coa;
        emit AuthorizedCOAUpdated(oldCOA, _coa);
    }

    // ============================================
    // User Functions
    // ============================================

    /// @notice Create a new Tide (deposit funds to create position)
    /// @param tokenAddress Address of token (use NATIVE_FLOW for native $FLOW)
    /// @param amount Amount to deposit
    function createTide(
        address tokenAddress,
        uint256 amount
    ) external payable returns (uint256) {
        require(amount > 0, "TidalRequests: amount must be greater than 0");

        if (isNativeFlow(tokenAddress)) {
            require(
                msg.value == amount,
                "TidalRequests: msg.value must equal amount"
            );
        } else {
            require(
                msg.value == 0,
                "TidalRequests: msg.value must be 0 for ERC20"
            );
            // TODO: Transfer ERC20 tokens (Phase 2)
            revert("TidalRequests: ERC20 not supported yet");
        }

        uint256 requestId = createRequest(
            RequestType.CREATE_TIDE,
            tokenAddress,
            amount,
            0 // No tideId yet
        );

        return requestId;
    }

    /// @notice Withdraw from existing Tide
    /// @param tideId The Tide ID to withdraw from
    /// @param amount Amount to withdraw
    function withdrawFromTide(
        uint64 tideId,
        uint256 amount
    ) external returns (uint256) {
        require(amount > 0, "TidalRequests: amount must be greater than 0");
        require(tideId > 0, "TidalRequests: invalid tide ID");

        uint256 requestId = createRequest(
            RequestType.WITHDRAW_FROM_TIDE,
            NATIVE_FLOW, // Assume FLOW for MVP
            amount,
            tideId
        );

        return requestId;
    }

    /// @notice Close Tide and withdraw all funds
    /// @param tideId The Tide ID to close
    function closeTide(uint64 tideId) external returns (uint256) {
        require(tideId > 0, "TidalRequests: invalid tide ID");

        uint256 requestId = createRequest(
            RequestType.CLOSE_TIDE,
            NATIVE_FLOW,
            0, // Amount will be determined by Cadence
            tideId
        );

        return requestId;
    }

    /// @notice Cancel a pending request and reclaim funds
    /// @param requestId The request ID to cancel
    function cancelRequest(uint256 requestId) external {
        Request storage request = pendingRequests[requestId];

        require(request.id == requestId, "TidalRequests: request not found");
        require(request.user == msg.sender, "TidalRequests: not request owner");
        require(
            request.status == RequestStatus.PENDING,
            "TidalRequests: can only cancel pending requests"
        );

        // Update status to FAILED with cancellation message
        request.status = RequestStatus.FAILED;
        request.message = "Cancelled by user";

        // Update in user's request array
        Request[] storage userReqs = userRequests[msg.sender];
        for (uint256 i = 0; i < userReqs.length; i++) {
            if (userReqs[i].id == requestId) {
                userReqs[i].status = RequestStatus.FAILED;
                userReqs[i].message = "Cancelled by user";
                break;
            }
        }

        // Remove from pending queue
        _removePendingRequest(requestId);

        // Refund funds if this was a CREATE_TIDE request
        uint256 refundAmount = 0;
        if (
            request.requestType == RequestType.CREATE_TIDE && request.amount > 0
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
                require(success, "TidalRequests: refund failed");
            } else {
                // TODO: Transfer ERC20 tokens (Phase 2)
                revert("TidalRequests: ERC20 not supported yet");
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
    // COA Functions (called by TidalEVM)
    // ============================================

    /// @notice Withdraw funds from contract (only authorized COA)
    /// @param tokenAddress Token to withdraw
    /// @param amount Amount to withdraw
    function withdrawFunds(
        address tokenAddress,
        uint256 amount
    ) external onlyAuthorizedCOA {
        require(amount > 0, "TidalRequests: amount must be greater than 0");

        if (isNativeFlow(tokenAddress)) {
            require(
                address(this).balance >= amount,
                "TidalRequests: insufficient balance"
            );
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "TidalRequests: transfer failed");
        } else {
            // TODO: Transfer ERC20 tokens (Phase 2)
            revert("TidalRequests: ERC20 not supported yet");
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
        require(request.id == requestId, "TidalRequests: request not found");
        require(
            request.status == RequestStatus.PENDING ||
                request.status == RequestStatus.PROCESSING,
            "TidalRequests: request already finalized"
        );

        // Convert uint8 to RequestStatus
        request.status = RequestStatus(status);
        request.message = message;
        if (tideId > 0) {
            request.tideId = tideId;
        }

        // Also update in user's request array
        Request[] storage userReqs = userRequests[request.user];
        for (uint256 i = 0; i < userReqs.length; i++) {
            if (userReqs[i].id == requestId) {
                userReqs[i].status = RequestStatus(status);
                userReqs[i].message = message;
                if (tideId > 0) {
                    userReqs[i].tideId = tideId;
                }
                break;
            }
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

    /// @notice Get user's request history
    function getUserRequests(
        address user
    ) external view returns (Request[] memory) {
        return userRequests[user];
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

    /// @notice Get pending requests (for worker to process)
    /// @dev This function is kept for backward compatibility but getPendingRequestsUnpacked(limit) is preferred
    function getPendingRequests() external view returns (Request[] memory) {
        Request[] memory requests = new Request[](pendingRequestIds.length);
        for (uint256 i = 0; i < pendingRequestIds.length; i++) {
            requests[i] = pendingRequests[pendingRequestIds[i]];
        }
        return requests;
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
            string[] memory messages
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

        // Populate arrays up to size
        for (uint256 i = 0; i < size; i++) {
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

    function createRequest(
        RequestType requestType,
        address tokenAddress,
        uint256 amount,
        uint64 tideId
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
            message: "" // Empty message initially
        });

        // Store in user's request array
        userRequests[user].push(newRequest);

        // Store in pending requests
        pendingRequests[requestId] = newRequest;
        pendingRequestIds.push(requestId);

        // Update pending user balance if depositing
        if (requestType == RequestType.CREATE_TIDE) {
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
        for (uint256 i = 0; i < pendingRequestIds.length; i++) {
            if (pendingRequestIds[i] == requestId) {
                // Move last element to this position and pop
                pendingRequestIds[i] = pendingRequestIds[
                    pendingRequestIds.length - 1
                ];
                pendingRequestIds.pop();
                break;
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
