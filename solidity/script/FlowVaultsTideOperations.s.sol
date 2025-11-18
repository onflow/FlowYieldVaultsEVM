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
 * - CREATE_TIDE:         forge script script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations --sig "runCreateTide(address)" <CONTRACT_ADDRESS> --broadcast
 * - DEPOSIT_TO_TIDE:     forge script script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations --sig "runDepositToTide(address,uint64)" <CONTRACT_ADDRESS> <TIDE_ID> --broadcast
 * - WITHDRAW_FROM_TIDE:  forge script script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations --sig "runWithdrawFromTide(address,uint64,uint256)" <CONTRACT_ADDRESS> <TIDE_ID> <AMOUNT> --broadcast
 * - CLOSE_TIDE:          forge script script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations --sig "runCloseTide(address,uint64)" <CONTRACT_ADDRESS> <TIDE_ID> --broadcast
 *
 * Environment Variables (optional):
 * - USER_PRIVATE_KEY: Private key for signing (defaults to test key 0x3)
 * - AMOUNT: Amount in wei for create/deposit operations (defaults to 10 ether)
 */
contract FlowVaultsTideOperations is Script {
    // ============================================
    // Configuration
    // ============================================

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
    /// @param contractAddress The FlowVaultsRequests contract address
    function runCreateTide(address contractAddress) public {
        uint256 userPrivateKey = vm.envOr("USER_PRIVATE_KEY", uint256(0x3));
        uint256 amount = vm.envOr("AMOUNT", DEFAULT_AMOUNT);
        address user = vm.addr(userPrivateKey);

        FlowVaultsRequests flowVaultsRequests = FlowVaultsRequests(
            payable(contractAddress)
        );

        createTide(flowVaultsRequests, user, userPrivateKey, amount);
    }

    /// @notice Deposit to an existing Tide with default or ENV-specified amount
    /// @param contractAddress The FlowVaultsRequests contract address
    /// @param tideId The Tide ID to deposit to
    function runDepositToTide(address contractAddress, uint64 tideId) public {
        uint256 userPrivateKey = vm.envOr("USER_PRIVATE_KEY", uint256(0x3));
        uint256 amount = vm.envOr("AMOUNT", DEFAULT_AMOUNT);
        address user = vm.addr(userPrivateKey);

        FlowVaultsRequests flowVaultsRequests = FlowVaultsRequests(
            payable(contractAddress)
        );

        depositToTide(flowVaultsRequests, user, userPrivateKey, tideId, amount);
    }

    /// @notice Withdraw from a Tide
    /// @param contractAddress The FlowVaultsRequests contract address
    /// @param tideId The Tide ID to withdraw from
    /// @param amount Amount to withdraw in wei
    function runWithdrawFromTide(
        address contractAddress,
        uint64 tideId,
        uint256 amount
    ) public {
        uint256 userPrivateKey = vm.envOr("USER_PRIVATE_KEY", uint256(0x3));
        address user = vm.addr(userPrivateKey);

        FlowVaultsRequests flowVaultsRequests = FlowVaultsRequests(
            payable(contractAddress)
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
    /// @param contractAddress The FlowVaultsRequests contract address
    /// @param tideId The Tide ID to close
    function runCloseTide(address contractAddress, uint64 tideId) public {
        uint256 userPrivateKey = vm.envOr("USER_PRIVATE_KEY", uint256(0x3));
        address user = vm.addr(userPrivateKey);

        FlowVaultsRequests flowVaultsRequests = FlowVaultsRequests(
            payable(contractAddress)
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
        require(user.balance >= amount, "Insufficient balance");

        vm.startBroadcast(userPrivateKey);

        uint256 requestId = flowVaultsRequests.depositToTide{value: amount}(
            tideId,
            NATIVE_FLOW,
            amount
        );

        vm.stopBroadcast();

        displayRequestDetails(flowVaultsRequests, requestId, user);
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
        vm.startBroadcast(userPrivateKey);

        uint256 requestId = flowVaultsRequests.withdrawFromTide(tideId, amount);

        vm.stopBroadcast();

        displayRequestDetails(flowVaultsRequests, requestId, user);
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
        vm.startBroadcast(userPrivateKey);

        uint256 requestId = flowVaultsRequests.closeTide(tideId);

        vm.stopBroadcast();

        displayRequestDetails(flowVaultsRequests, requestId, user);
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

        if (bytes(request.vaultIdentifier).length > 0) {
            console.log("Vault:", request.vaultIdentifier);
        }
        if (bytes(request.strategyIdentifier).length > 0) {
            console.log("Strategy:", request.strategyIdentifier);
        }

        uint256[] memory pendingIds = flowVaultsRequests.getPendingRequestIds();

        uint256 userBalance = flowVaultsRequests.getUserBalance(
            user,
            NATIVE_FLOW
        );
    }
}
