// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

/**
 * @title TidalRequests
 * @notice Request queue and fund escrow for EVM users to interact with Tidal Cadence protocol
 * @dev This contract holds user funds in escrow until processed by TidalEVMWorker
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
    }

    // ============================================
    // State Variables
    // ============================================

    /// @notice Auto-incrementing request ID counter
    uint256 private _requestIdCounter;

    /// @notice Authorized COA address (controlled by TidalEVMWorker)
    address public authorizedCOA;

    /// @notice Owner of the contract (for admin functions)
    address public owner;

    /// @notice User request history: user address => array of requests
    mapping(address => Request[]) public userRequests;

    /// @notice User balances: user address => token address => balance
    mapping(address => mapping(address => uint256)) public userBalances;

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
        uint64 tideId
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
    /// @param _coa The COA address controlled by TidalEVMWorker
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

    // ============================================
    // COA Functions (called by TidalEVMWorker)
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
    /// @param status New status
    /// @param tideId Associated Tide ID (if applicable)
    function updateRequestStatus(
        uint256 requestId,
        RequestStatus status,
        uint64 tideId
    ) external onlyAuthorizedCOA {
        Request storage request = pendingRequests[requestId];
        require(request.id == requestId, "TidalRequests: request not found");
        require(
            request.status == RequestStatus.PENDING ||
                request.status == RequestStatus.PROCESSING,
            "TidalRequests: request already finalized"
        );

        request.status = status;
        if (tideId > 0) {
            request.tideId = tideId;
        }

        // Also update in user's request array
        Request[] storage userReqs = userRequests[request.user];
        for (uint256 i = 0; i < userReqs.length; i++) {
            if (userReqs[i].id == requestId) {
                userReqs[i].status = status;
                if (tideId > 0) {
                    userReqs[i].tideId = tideId;
                }
                break;
            }
        }

        // If completed or failed, remove from pending queue
        if (
            status == RequestStatus.COMPLETED || status == RequestStatus.FAILED
        ) {
            _removePendingRequest(requestId);
        }

        emit RequestProcessed(requestId, status, tideId);
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
        userBalances[user][tokenAddress] = newBalance;
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

    /// @notice Get user's balance for a token
    function getUserBalance(
        address user,
        address tokenAddress
    ) external view returns (uint256) {
        return userBalances[user][tokenAddress];
    }

    /// @notice Get all pending request IDs
    function getPendingRequestIds() external view returns (uint256[] memory) {
        return pendingRequestIds;
    }

    /// @notice Get pending requests (for worker to process)
    function getPendingRequests() external view returns (Request[] memory) {
        Request[] memory requests = new Request[](pendingRequestIds.length);
        for (uint256 i = 0; i < pendingRequestIds.length; i++) {
            requests[i] = pendingRequests[pendingRequestIds[i]];
        }
        return requests;
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
            timestamp: block.timestamp
        });

        // Store in user's request array
        userRequests[user].push(newRequest);

        // Store in pending requests
        pendingRequests[requestId] = newRequest;
        pendingRequestIds.push(requestId);

        // Update user balance if depositing
        if (requestType == RequestType.CREATE_TIDE) {
            userBalances[user][tokenAddress] += amount;
            emit BalanceUpdated(
                user,
                tokenAddress,
                userBalances[user][tokenAddress]
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
