// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Script.sol";
import "../src/TidalRequests.sol";

/**
 * @title CreateTideRequest
 * @notice Script for user A to create a tide request on EVM side
 * @dev This script:
 *      1. Creates a request to create a tide with 1 FLOW
 *      2. Sends the request to TidalRequests contract
 *      3. Logs the request ID for tracking
 */
contract CreateTideRequest is Script {
    // TidalRequests contract address on emulator
    address constant TIDAL_REQUESTS =
        0x153b84F377C6C7a7D93Bd9a717E48097Ca6Cfd11; // Got the address from emulator after deployment

    // NATIVE_FLOW constant (must match TidalRequests.sol)
    address constant NATIVE_FLOW = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    // Amount to deposit (1 FLOW = 1 ether in wei)
    uint256 constant AMOUNT = 1 ether;

    function run() external {
        // Get user A's private key from environment or use default
        uint256 userPrivateKey = vm.envOr("USER_PRIVATE_KEY", uint256(0x3));

        // Get user A's address
        address userA = vm.addr(userPrivateKey);

        console.log("User A address:", userA);
        console.log("User A balance:", userA.balance);

        // Start broadcasting transactions as user A
        vm.startBroadcast(userPrivateKey);

        // Create TidalRequests interface
        TidalRequests tidalRequests = TidalRequests(payable(TIDAL_REQUESTS));

        console.log("\n=== Creating Tide Request ===");
        console.log("Amount:", AMOUNT);
        console.log("Token:", NATIVE_FLOW);

        // Check user has enough balance (should pass now)
        require(userA.balance >= AMOUNT, "Insufficient balance");

        // Create the tide request
        uint256 requestId = tidalRequests.createTide{value: AMOUNT}(
            NATIVE_FLOW,
            AMOUNT
        );

        console.log("\n=== Request Created ===");
        console.log("Request ID:", requestId);
        console.log("User balance after:", userA.balance);

        // Get and display request details
        TidalRequests.Request memory request = tidalRequests.getRequest(
            requestId
        );
        console.log("\n=== Request Details ===");
        console.log("Request ID:", request.id);
        console.log("User:", request.user);
        console.log("Type:", uint256(request.requestType));
        console.log("Status:", uint256(request.status));
        console.log("Token:", request.tokenAddress);
        console.log("Amount:", request.amount);
        console.log("Timestamp:", request.timestamp);

        // Get pending requests count
        uint256[] memory pendingIds = tidalRequests.getPendingRequestIds();
        console.log("\n=== Pending Requests ===");
        console.log("Total pending:", pendingIds.length);

        // Get user's balance in contract
        uint256 userBalance = tidalRequests.getUserBalance(userA, NATIVE_FLOW);
        console.log("\n=== User Balance in Contract ===");
        console.log("Balance:", userBalance);

        vm.stopBroadcast();

        console.log("\n=== Next Steps ===");
        console.log("1. Note the Request ID:", requestId);
        console.log("2. Run Cadence transaction to process this request");
        console.log("3. User EVM address for tracking:", userA);
    }
}
