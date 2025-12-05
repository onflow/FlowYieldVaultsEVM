// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FlowYieldVaultsRequests} from "../src/FlowYieldVaultsRequests.sol";

/**
 * @title FlowYieldVaultsYieldVaultOperations
 * @notice Script for executing Flow YieldVaults YieldVault operations on the EVM side
 * @dev Supports all four request types: CREATE_YIELDVAULT, DEPOSIT_TO_YIELDVAULT, WITHDRAW_FROM_YIELDVAULT, CLOSE_YIELDVAULT
 *
 * Usage Examples:
 *
 *   # Create a new YieldVault
 *   forge script script/FlowYieldVaultsYieldVaultOperations.s.sol:FlowYieldVaultsYieldVaultOperations \
 *     --sig "createYieldVault(address)" <CONTRACT_ADDRESS> \
 *     --rpc-url $RPC_URL --broadcast
 *
 *   # Deposit to existing YieldVault
 *   forge script script/FlowYieldVaultsYieldVaultOperations.s.sol:FlowYieldVaultsYieldVaultOperations \
 *     --sig "depositToYieldVault(address,uint64)" <CONTRACT_ADDRESS> <YIELD_VAULT_ID> \
 *     --rpc-url $RPC_URL --broadcast
 *
 *   # Withdraw from YieldVault
 *   forge script script/FlowYieldVaultsYieldVaultOperations.s.sol:FlowYieldVaultsYieldVaultOperations \
 *     --sig "withdrawFromYieldVault(address,uint64,uint256)" <CONTRACT_ADDRESS> <YIELD_VAULT_ID> <AMOUNT_WEI> \
 *     --rpc-url $RPC_URL --broadcast
 *
 *   # Close YieldVault
 *   forge script script/FlowYieldVaultsYieldVaultOperations.s.sol:FlowYieldVaultsYieldVaultOperations \
 *     --sig "closeYieldVault(address,uint64)" <CONTRACT_ADDRESS> <YIELD_VAULT_ID> \
 *     --rpc-url $RPC_URL --broadcast
 *
 * Environment Variables:
 *   - USER_PRIVATE_KEY: Private key for signing transactions (defaults to 0x3 for testing)
 *   - AMOUNT: Amount in wei for create/deposit operations (defaults to 10 ether)
 *   - VAULT_IDENTIFIER: Cadence vault type identifier (defaults to emulator address)
 *   - STRATEGY_IDENTIFIER: Cadence strategy type identifier (defaults to emulator address)
 */
contract FlowYieldVaultsYieldVaultOperations is Script {
    /// @dev Sentinel address for native $FLOW (must match FlowYieldVaultsRequests.NATIVE_FLOW)
    address constant NATIVE_FLOW = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    /// @dev Default amount for create/deposit operations
    uint256 constant DEFAULT_AMOUNT = 10 ether;

    /// @dev Default vault identifier (emulator)
    string constant DEFAULT_VAULT_IDENTIFIER =
        "A.0ae53cb6e3f42a79.FlowToken.Vault";

    /// @dev Default strategy identifier (emulator)
    string constant DEFAULT_STRATEGY_IDENTIFIER =
        "A.045a1763c93006ca.FlowYieldVaultsStrategies.TracerStrategy";

    /// @notice Creates a new YieldVault by depositing native $FLOW
    /// @param contractAddress The FlowYieldVaultsRequests contract address
    function createYieldVault(address contractAddress) public {
        (uint256 privateKey, address user) = _getUser();
        uint256 amount = vm.envOr("AMOUNT", DEFAULT_AMOUNT);
        string memory vaultId = vm.envOr(
            "VAULT_IDENTIFIER",
            DEFAULT_VAULT_IDENTIFIER
        );
        string memory strategyId = vm.envOr(
            "STRATEGY_IDENTIFIER",
            DEFAULT_STRATEGY_IDENTIFIER
        );

        FlowYieldVaultsRequests requests = FlowYieldVaultsRequests(
            payable(contractAddress)
        );

        require(user.balance >= amount, "Insufficient balance");

        vm.startBroadcast(privateKey);
        uint256 requestId = requests.createYieldVault{value: amount}(
            NATIVE_FLOW,
            amount,
            vaultId,
            strategyId
        );
        vm.stopBroadcast();

        _logRequestCreated("CREATE_YIELDVAULT", requestId, user, amount);
        _logRequestDetails(requests, requestId);
    }

    /// @notice Deposits additional funds to an existing YieldVault
    /// @dev Anyone can deposit to any valid YieldVault (not restricted to owner)
    /// @param contractAddress The FlowYieldVaultsRequests contract address
    /// @param yieldVaultId The YieldVault Id to deposit to
    function depositToYieldVault(
        address contractAddress,
        uint64 yieldVaultId
    ) public {
        (uint256 privateKey, address user) = _getUser();
        uint256 amount = vm.envOr("AMOUNT", DEFAULT_AMOUNT);

        FlowYieldVaultsRequests requests = FlowYieldVaultsRequests(
            payable(contractAddress)
        );

        require(user.balance >= amount, "Insufficient balance");

        vm.startBroadcast(privateKey);
        uint256 requestId = requests.depositToYieldVault{value: amount}(
            yieldVaultId,
            NATIVE_FLOW,
            amount
        );
        vm.stopBroadcast();

        _logRequestCreated("DEPOSIT_TO_YIELDVAULT", requestId, user, amount);
        console.log("YieldVault Id:", yieldVaultId);
    }

    /// @notice Requests a withdrawal from an existing YieldVault
    /// @param contractAddress The FlowYieldVaultsRequests contract address
    /// @param yieldVaultId The YieldVault Id to withdraw from
    /// @param amount Amount to withdraw in wei
    function withdrawFromYieldVault(
        address contractAddress,
        uint64 yieldVaultId,
        uint256 amount
    ) public {
        (uint256 privateKey, address user) = _getUser();

        FlowYieldVaultsRequests requests = FlowYieldVaultsRequests(
            payable(contractAddress)
        );

        require(
            requests.doesUserOwnYieldVault(user, yieldVaultId),
            "User does not own this YieldVault"
        );

        vm.startBroadcast(privateKey);
        uint256 requestId = requests.withdrawFromYieldVault(
            yieldVaultId,
            amount
        );
        vm.stopBroadcast();

        _logRequestCreated("WITHDRAW_FROM_YIELDVAULT", requestId, user, amount);
        console.log("YieldVault Id:", yieldVaultId);
    }

    /// @notice Requests closure of a YieldVault and withdrawal of all funds
    /// @param contractAddress The FlowYieldVaultsRequests contract address
    /// @param yieldVaultId The YieldVault Id to close
    function closeYieldVault(
        address contractAddress,
        uint64 yieldVaultId
    ) public {
        (uint256 privateKey, address user) = _getUser();

        FlowYieldVaultsRequests requests = FlowYieldVaultsRequests(
            payable(contractAddress)
        );

        require(
            requests.doesUserOwnYieldVault(user, yieldVaultId),
            "User does not own this YieldVault"
        );

        vm.startBroadcast(privateKey);
        uint256 requestId = requests.closeYieldVault(yieldVaultId);
        vm.stopBroadcast();

        _logRequestCreated("CLOSE_YIELDVAULT", requestId, user, 0);
        console.log("YieldVault Id:", yieldVaultId);
    }

    /// @notice Cancels a pending request and refunds funds
    /// @param contractAddress The FlowYieldVaultsRequests contract address
    /// @param requestId The request ID to cancel
    function cancelRequest(address contractAddress, uint256 requestId) public {
        (uint256 privateKey, address user) = _getUser();

        FlowYieldVaultsRequests requests = FlowYieldVaultsRequests(
            payable(contractAddress)
        );
        FlowYieldVaultsRequests.Request memory req = requests.getRequest(
            requestId
        );

        require(req.user == user, "Not request owner");
        require(
            req.status == FlowYieldVaultsRequests.RequestStatus.PENDING,
            "Request not pending"
        );

        vm.startBroadcast(privateKey);
        requests.cancelRequest(requestId);
        vm.stopBroadcast();

        console.log("Request cancelled:", requestId);
        console.log("User:", user);
    }

    /// @notice Gets user's pending balance for native $FLOW
    /// @param contractAddress The FlowYieldVaultsRequests contract address
    /// @param user The user address to check
    function getPendingBalance(
        address contractAddress,
        address user
    ) public view {
        FlowYieldVaultsRequests requests = FlowYieldVaultsRequests(
            payable(contractAddress)
        );
        uint256 balance = requests.getUserPendingBalance(user, NATIVE_FLOW);

        console.log("User:", user);
        console.log("Pending FLOW balance:", balance);
    }

    /// @notice Gets all YieldVault Ids owned by a user
    /// @param contractAddress The FlowYieldVaultsRequests contract address
    /// @param user The user address to check
    function getUserYieldVaults(
        address contractAddress,
        address user
    ) public view {
        FlowYieldVaultsRequests requests = FlowYieldVaultsRequests(
            payable(contractAddress)
        );
        uint64[] memory yieldVaults = requests.getYieldVaultIdsForUser(user);

        console.log("User:", user);
        console.log("YieldVault count:", yieldVaults.length);
        for (uint256 i = 0; i < yieldVaults.length; i++) {
            console.log("  YieldVault Id:", yieldVaults[i]);
        }
    }

    /// @notice Gets the count of pending requests
    /// @param contractAddress The FlowYieldVaultsRequests contract address
    function getPendingRequestCount(address contractAddress) public view {
        FlowYieldVaultsRequests requests = FlowYieldVaultsRequests(
            payable(contractAddress)
        );
        uint256 count = requests.getPendingRequestCount();

        console.log("Pending requests:", count);
    }

    /// @dev Returns the user's private key and address from environment or defaults
    function _getUser()
        internal
        view
        returns (uint256 privateKey, address user)
    {
        privateKey = vm.envOr("USER_PRIVATE_KEY", uint256(0x3));
        user = vm.addr(privateKey);
    }

    /// @dev Logs basic request creation info
    function _logRequestCreated(
        string memory operation,
        uint256 requestId,
        address user,
        uint256 amount
    ) internal pure {
        console.log("=== Operation:", operation, "===");
        console.log("Request ID:", requestId);
        console.log("User:", user);
        if (amount > 0) {
            console.log("Amount:", amount);
        }
    }

    /// @dev Logs detailed request information
    function _logRequestDetails(
        FlowYieldVaultsRequests requests,
        uint256 requestId
    ) internal view {
        FlowYieldVaultsRequests.Request memory req = requests.getRequest(
            requestId
        );

        if (bytes(req.vaultIdentifier).length > 0) {
            console.log("Vault:", req.vaultIdentifier);
        }
        if (bytes(req.strategyIdentifier).length > 0) {
            console.log("Strategy:", req.strategyIdentifier);
        }
        console.log("Pending requests:", requests.getPendingRequestCount());
    }
}
