// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FlowVaultsRequests} from "../src/FlowVaultsRequests.sol";

/**
 * @title FlowVaultsTideOperations
 * @notice Script for executing Flow Vaults Tide operations on the EVM side
 * @dev Supports all four request types: CREATE_TIDE, DEPOSIT_TO_TIDE, WITHDRAW_FROM_TIDE, CLOSE_TIDE
 *
 * Usage Examples:
 *
 *   # Create a new Tide
 *   forge script script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
 *     --sig "createTide(address)" <CONTRACT_ADDRESS> \
 *     --rpc-url $RPC_URL --broadcast
 *
 *   # Deposit to existing Tide
 *   forge script script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
 *     --sig "depositToTide(address,uint64)" <CONTRACT_ADDRESS> <TIDE_ID> \
 *     --rpc-url $RPC_URL --broadcast
 *
 *   # Withdraw from Tide
 *   forge script script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
 *     --sig "withdrawFromTide(address,uint64,uint256)" <CONTRACT_ADDRESS> <TIDE_ID> <AMOUNT_WEI> \
 *     --rpc-url $RPC_URL --broadcast
 *
 *   # Close Tide
 *   forge script script/FlowVaultsTideOperations.s.sol:FlowVaultsTideOperations \
 *     --sig "closeTide(address,uint64)" <CONTRACT_ADDRESS> <TIDE_ID> \
 *     --rpc-url $RPC_URL --broadcast
 *
 * Environment Variables:
 *   - USER_PRIVATE_KEY: Private key for signing transactions (defaults to 0x3 for testing)
 *   - AMOUNT: Amount in wei for create/deposit operations (defaults to 10 ether)
 *   - VAULT_IDENTIFIER: Cadence vault type identifier (defaults to emulator address)
 *   - STRATEGY_IDENTIFIER: Cadence strategy type identifier (defaults to emulator address)
 */
contract FlowVaultsTideOperations is Script {
    /// @dev Sentinel address for native $FLOW (must match FlowVaultsRequests.NATIVE_FLOW)
    address constant NATIVE_FLOW = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    /// @dev Default amount for create/deposit operations
    uint256 constant DEFAULT_AMOUNT = 10 ether;

    /// @dev Default vault identifier (emulator)
    string constant DEFAULT_VAULT_IDENTIFIER = "A.0ae53cb6e3f42a79.FlowToken.Vault";

    /// @dev Default strategy identifier (emulator)
    string constant DEFAULT_STRATEGY_IDENTIFIER = "A.045a1763c93006ca.FlowVaultsStrategies.TracerStrategy";

    /// @notice Creates a new Tide by depositing native $FLOW
    /// @param contractAddress The FlowVaultsRequests contract address
    function createTide(address contractAddress) public {
        (uint256 privateKey, address user) = _getUser();
        uint256 amount = vm.envOr("AMOUNT", DEFAULT_AMOUNT);
        string memory vaultId = vm.envOr("VAULT_IDENTIFIER", DEFAULT_VAULT_IDENTIFIER);
        string memory strategyId = vm.envOr("STRATEGY_IDENTIFIER", DEFAULT_STRATEGY_IDENTIFIER);

        FlowVaultsRequests requests = FlowVaultsRequests(payable(contractAddress));

        require(user.balance >= amount, "Insufficient balance");

        vm.startBroadcast(privateKey);
        uint256 requestId = requests.createTide{value: amount}(NATIVE_FLOW, amount, vaultId, strategyId);
        vm.stopBroadcast();

        _logRequestCreated("CREATE_TIDE", requestId, user, amount);
        _logRequestDetails(requests, requestId);
    }

    /// @notice Deposits additional funds to an existing Tide
    /// @dev Anyone can deposit to any valid Tide (not restricted to owner)
    /// @param contractAddress The FlowVaultsRequests contract address
    /// @param tideId The Tide ID to deposit to
    function depositToTide(address contractAddress, uint64 tideId) public {
        (uint256 privateKey, address user) = _getUser();
        uint256 amount = vm.envOr("AMOUNT", DEFAULT_AMOUNT);

        FlowVaultsRequests requests = FlowVaultsRequests(payable(contractAddress));

        require(user.balance >= amount, "Insufficient balance");

        vm.startBroadcast(privateKey);
        uint256 requestId = requests.depositToTide{value: amount}(tideId, NATIVE_FLOW, amount);
        vm.stopBroadcast();

        _logRequestCreated("DEPOSIT_TO_TIDE", requestId, user, amount);
        console.log("Tide ID:", tideId);
    }

    /// @notice Requests a withdrawal from an existing Tide
    /// @param contractAddress The FlowVaultsRequests contract address
    /// @param tideId The Tide ID to withdraw from
    /// @param amount Amount to withdraw in wei
    function withdrawFromTide(address contractAddress, uint64 tideId, uint256 amount) public {
        (uint256 privateKey, address user) = _getUser();

        FlowVaultsRequests requests = FlowVaultsRequests(payable(contractAddress));

        require(requests.doesUserOwnTide(user, tideId), "User does not own this Tide");

        vm.startBroadcast(privateKey);
        uint256 requestId = requests.withdrawFromTide(tideId, amount);
        vm.stopBroadcast();

        _logRequestCreated("WITHDRAW_FROM_TIDE", requestId, user, amount);
        console.log("Tide ID:", tideId);
    }

    /// @notice Requests closure of a Tide and withdrawal of all funds
    /// @param contractAddress The FlowVaultsRequests contract address
    /// @param tideId The Tide ID to close
    function closeTide(address contractAddress, uint64 tideId) public {
        (uint256 privateKey, address user) = _getUser();

        FlowVaultsRequests requests = FlowVaultsRequests(payable(contractAddress));

        require(requests.doesUserOwnTide(user, tideId), "User does not own this Tide");

        vm.startBroadcast(privateKey);
        uint256 requestId = requests.closeTide(tideId);
        vm.stopBroadcast();

        _logRequestCreated("CLOSE_TIDE", requestId, user, 0);
        console.log("Tide ID:", tideId);
    }

    /// @notice Cancels a pending request and refunds funds
    /// @param contractAddress The FlowVaultsRequests contract address
    /// @param requestId The request ID to cancel
    function cancelRequest(address contractAddress, uint256 requestId) public {
        (uint256 privateKey, address user) = _getUser();

        FlowVaultsRequests requests = FlowVaultsRequests(payable(contractAddress));
        FlowVaultsRequests.Request memory req = requests.getRequest(requestId);

        require(req.user == user, "Not request owner");
        require(req.status == FlowVaultsRequests.RequestStatus.PENDING, "Request not pending");

        vm.startBroadcast(privateKey);
        requests.cancelRequest(requestId);
        vm.stopBroadcast();

        console.log("Request cancelled:", requestId);
        console.log("User:", user);
    }

    /// @notice Gets user's pending balance for native $FLOW
    /// @param contractAddress The FlowVaultsRequests contract address
    /// @param user The user address to check
    function getPendingBalance(address contractAddress, address user) public view {
        FlowVaultsRequests requests = FlowVaultsRequests(payable(contractAddress));
        uint256 balance = requests.getUserPendingBalance(user, NATIVE_FLOW);

        console.log("User:", user);
        console.log("Pending FLOW balance:", balance);
    }

    /// @notice Gets all Tide IDs owned by a user
    /// @param contractAddress The FlowVaultsRequests contract address
    /// @param user The user address to check
    function getUserTides(address contractAddress, address user) public view {
        FlowVaultsRequests requests = FlowVaultsRequests(payable(contractAddress));
        uint64[] memory tides = requests.getTideIDsForUser(user);

        console.log("User:", user);
        console.log("Tide count:", tides.length);
        for (uint256 i = 0; i < tides.length; i++) {
            console.log("  Tide ID:", tides[i]);
        }
    }

    /// @notice Gets the count of pending requests
    /// @param contractAddress The FlowVaultsRequests contract address
    function getPendingRequestCount(address contractAddress) public view {
        FlowVaultsRequests requests = FlowVaultsRequests(payable(contractAddress));
        uint256 count = requests.getPendingRequestCount();

        console.log("Pending requests:", count);
    }

    /// @dev Returns the user's private key and address from environment or defaults
    function _getUser() internal view returns (uint256 privateKey, address user) {
        privateKey = vm.envOr("USER_PRIVATE_KEY", uint256(0x3));
        user = vm.addr(privateKey);
    }

    /// @dev Logs basic request creation info
    function _logRequestCreated(string memory operation, uint256 requestId, address user, uint256 amount) internal pure {
        console.log("=== Operation:", operation, "===");
        console.log("Request ID:", requestId);
        console.log("User:", user);
        if (amount > 0) {
            console.log("Amount:", amount);
        }
    }

    /// @dev Logs detailed request information
    function _logRequestDetails(FlowVaultsRequests requests, uint256 requestId) internal view {
        FlowVaultsRequests.Request memory req = requests.getRequest(requestId);

        if (bytes(req.vaultIdentifier).length > 0) {
            console.log("Vault:", req.vaultIdentifier);
        }
        if (bytes(req.strategyIdentifier).length > 0) {
            console.log("Strategy:", req.strategyIdentifier);
        }
        console.log("Pending requests:", requests.getPendingRequestCount());
    }
}
