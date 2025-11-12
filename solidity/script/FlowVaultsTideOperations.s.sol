// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Script.sol";
import "../src/FlowVaultsRequests.sol";

/**
 * @title FlowVaultsTideOperations
 * @notice Unified script for all Flow Vaults Tide operations on EVM side
 * @dev Supports: CREATE_TIDE, DEPOSIT_TO_TIDE, WITHDRAW_FROM_TIDE, CLOSE_TIDE
 *
 * Usage:
 * - CREATE_TIDE:         forge script script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations --sig "runCreateTide()" --broadcast
 * - DEPOSIT_TO_TIDE:     forge script script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations --sig "runDepositToTide(uint64)" <TIDE_ID> --broadcast
 * - WITHDRAW_FROM_TIDE:  forge script script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations --sig "runWithdrawFromTide(uint64,uint256)" <TIDE_ID> <AMOUNT> --broadcast
 * - CLOSE_TIDE:          forge script script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations --sig "runCloseTide(uint64)" <TIDE_ID> --broadcast
 *
 * Environment Variables (optional):
 * - USER_PRIVATE_KEY: Private key for signing (defaults to test key 0x3)
 * - AMOUNT: Amount in wei for create/deposit operations (defaults to 10 ether)
 */
contract FlowVaultsTideOperations is Script {
    // ============================================
    // Configuration
    // ============================================

    // FlowVaultsRequests contract address (update based on deployment)
    address constant FLOW_VAULTS_REQUESTS =
        0x153b84F377C6C7a7D93Bd9a717E48097Ca6Cfd11;

    // NATIVE_FLOW constant (must match FlowVaultsRequests.sol)
    address constant NATIVE_FLOW = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    // Default amount for operations (can be overridden via env var)
    uint256 constant DEFAULT_AMOUNT = 10 ether;

    // Vault and strategy identifiers for testnet
    // string constant VAULT_IDENTIFIER = "A.7e60df042a9c0868.FlowToken.Vault";
    // string constant STRATEGY_IDENTIFIER =
    //     "A.3bda2f90274dbc9b.FlowVaultsStrategies.TracerStrategy";

    // Vault and strategy identifiers for emulator - CI testing
    string constant VAULT_IDENTIFIER = "A.0ae53cb6e3f42a79.FlowToken.Vault";
    string constant STRATEGY_IDENTIFIER =
        "A.045a1763c93006ca.FlowVaultsStrategies.TracerStrategy";

    // ============================================
    // Public Entry Points
    // ============================================

    /// @notice Create a new Tide with default or ENV-specified amount
    function runCreateTide() public {
        uint256 userPrivateKey = vm.envOr("USER_PRIVATE_KEY", uint256(0x3));
        uint256 amount = vm.envOr("AMOUNT", DEFAULT_AMOUNT);
        address user = vm.addr(userPrivateKey);

        FlowVaultsRequests flowVaultsRequests = FlowVaultsRequests(
            payable(FLOW_VAULTS_REQUESTS)
        );

        createTide(flowVaultsRequests, user, userPrivateKey, amount);
    }

    /// @notice Deposit to an existing Tide with default or ENV-specified amount
    /// @param tideId The Tide ID to deposit to
    function runDepositToTide(uint64 tideId) public {
        uint256 userPrivateKey = vm.envOr("USER_PRIVATE_KEY", uint256(0x3));
        uint256 amount = vm.envOr("AMOUNT", DEFAULT_AMOUNT);
        address user = vm.addr(userPrivateKey);

        FlowVaultsRequests flowVaultsRequests = FlowVaultsRequests(
            payable(FLOW_VAULTS_REQUESTS)
        );

        depositToTide(flowVaultsRequests, user, userPrivateKey, tideId, amount);
    }

    /// @notice Withdraw from a Tide
    /// @param tideId The Tide ID to withdraw from
    /// @param amount Amount to withdraw in wei
    function runWithdrawFromTide(uint64 tideId, uint256 amount) public {
        uint256 userPrivateKey = vm.envOr("USER_PRIVATE_KEY", uint256(0x3));
        address user = vm.addr(userPrivateKey);

        FlowVaultsRequests flowVaultsRequests = FlowVaultsRequests(
            payable(FLOW_VAULTS_REQUESTS)
        );

        withdrawFromTide(
            flowVaultsRequests,
            user,
            userPrivateKey,
            tideId,
            amount
        );
    }

    /// @notice Close a Tide and withdraw all funds
    /// @param tideId The Tide ID to close
    function runCloseTide(uint64 tideId) public {
        uint256 userPrivateKey = vm.envOr("USER_PRIVATE_KEY", uint256(0x3));
        address user = vm.addr(userPrivateKey);

        FlowVaultsRequests flowVaultsRequests = FlowVaultsRequests(
            payable(FLOW_VAULTS_REQUESTS)
        );

        closeTide(flowVaultsRequests, user, userPrivateKey, tideId);
    }

    // ============================================
    // Internal Implementation Functions
    // ============================================

    function createTide(
        FlowVaultsRequests flowVaultsRequests,
        address user,
        uint256 userPrivateKey,
        uint256 amount
    ) internal {
        console.log("\n=== Creating New Tide ===");
        console.log("Amount:", amount);
        console.log("Vault:", VAULT_IDENTIFIER);
        console.log("Strategy:", STRATEGY_IDENTIFIER);

        require(user.balance >= amount, "Insufficient balance");

        vm.startBroadcast(userPrivateKey);

        uint256 requestId = flowVaultsRequests.createTide{value: amount}(
            NATIVE_FLOW,
            amount,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

        vm.stopBroadcast();

        displayRequestDetails(flowVaultsRequests, requestId, user);

        console.log("\n=== Next Steps ===");
        console.log("1. Note the Request ID:", requestId);
        console.log("2. Run Cadence worker to process this request");
        console.log("3. Tide ID will be assigned after processing");
    }

    // ============================================
    // Operation: DEPOSIT_TO_TIDE
    // ============================================

    function depositToTide(
        FlowVaultsRequests flowVaultsRequests,
        address user,
        uint256 userPrivateKey,
        uint64 tideId,
        uint256 amount
    ) internal {
        require(tideId > 0, "TIDE_ID must be set for deposit operation");

        console.log("\n=== Depositing to Existing Tide ===");
        console.log("Tide ID:", tideId);
        console.log("Amount:", amount);

        require(user.balance >= amount, "Insufficient balance");

        vm.startBroadcast(userPrivateKey);

        uint256 requestId = flowVaultsRequests.depositToTide{value: amount}(
            tideId,
            NATIVE_FLOW,
            amount
        );

        vm.stopBroadcast();

        displayRequestDetails(flowVaultsRequests, requestId, user);

        console.log("\n=== Next Steps ===");
        console.log("1. Note the Request ID:", requestId);
        console.log("2. Run Cadence worker to process this deposit");
    }

    // ============================================
    // Operation: WITHDRAW_FROM_TIDE
    // ============================================

    function withdrawFromTide(
        FlowVaultsRequests flowVaultsRequests,
        address user,
        uint256 userPrivateKey,
        uint64 tideId,
        uint256 amount
    ) internal {
        require(tideId > 0, "TIDE_ID must be set for withdraw operation");

        console.log("\n=== Withdrawing from Tide ===");
        console.log("Tide ID:", tideId);
        console.log("Amount:", amount);

        vm.startBroadcast(userPrivateKey);

        uint256 requestId = flowVaultsRequests.withdrawFromTide(tideId, amount);

        vm.stopBroadcast();

        displayRequestDetails(flowVaultsRequests, requestId, user);

        console.log("\n=== Next Steps ===");
        console.log("1. Note the Request ID:", requestId);
        console.log("2. Run Cadence worker to process this withdrawal");
        console.log("3. Funds will be returned to your EVM address");
    }

    // ============================================
    // Operation: CLOSE_TIDE
    // ============================================

    function closeTide(
        FlowVaultsRequests flowVaultsRequests,
        address user,
        uint256 userPrivateKey,
        uint64 tideId
    ) internal {
        require(tideId > 0, "TIDE_ID must be set for close operation");

        console.log("\n=== Closing Tide ===");
        console.log("Tide ID:", tideId);

        vm.startBroadcast(userPrivateKey);

        uint256 requestId = flowVaultsRequests.closeTide(tideId);

        vm.stopBroadcast();

        displayRequestDetails(flowVaultsRequests, requestId, user);

        console.log("\n=== Next Steps ===");
        console.log("1. Note the Request ID:", requestId);
        console.log("2. Run Cadence worker to process this closure");
        console.log("3. All funds will be returned to your EVM address");
    }

    // ============================================
    // Helper Functions
    // ============================================

    function displayRequestDetails(
        FlowVaultsRequests flowVaultsRequests,
        uint256 requestId,
        address user
    ) internal view {
        FlowVaultsRequests.Request memory request = flowVaultsRequests
            .getRequest(requestId);

        console.log("\n=== Request Created ===");
        console.log("Request ID:", request.id);
        console.log("User:", request.user);
        console.log("Type:", uint256(request.requestType));
        console.log("Status:", uint256(request.status));
        console.log("Token:", request.tokenAddress);
        console.log("Amount:", request.amount);
        console.log("Tide ID:", request.tideId);
        console.log("Timestamp:", request.timestamp);

        if (bytes(request.vaultIdentifier).length > 0) {
            console.log("Vault:", request.vaultIdentifier);
        }
        if (bytes(request.strategyIdentifier).length > 0) {
            console.log("Strategy:", request.strategyIdentifier);
        }

        uint256[] memory pendingIds = flowVaultsRequests.getPendingRequestIds();
        console.log("\n=== Queue Status ===");
        console.log("Total pending requests:", pendingIds.length);

        uint256 userBalance = flowVaultsRequests.getUserBalance(
            user,
            NATIVE_FLOW
        );
        console.log("Your pending balance:", userBalance);
        console.log("Your wallet balance:", user.balance);
    }
}
