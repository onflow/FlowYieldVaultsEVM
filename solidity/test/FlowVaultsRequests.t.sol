// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Test.sol";
import "../src/FlowVaultsRequests.sol";

contract FlowVaultsRequestsTest is Test {
    FlowVaultsRequests public c; // Short name for brevity
    address user = makeAddr("user");
    address coa = makeAddr("coa");
    address constant NATIVE_FLOW = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    function setUp() public {
        vm.deal(user, 100 ether);
        c = new FlowVaultsRequests(coa);
    }

    // ============================================
    // CREATE_TIDE Flow
    // ============================================
    function test_CreateTide() public {
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether);

        assertEq(reqId, 1);
        assertEq(c.getUserBalance(user, NATIVE_FLOW), 1 ether);
        assertEq(c.getPendingRequestCount(), 1);

        FlowVaultsRequests.Request[] memory reqs = c.getUserRequests(user);
        assertEq(
            uint8(reqs[0].requestType),
            uint8(FlowVaultsRequests.RequestType.CREATE_TIDE)
        );
    }

    function test_CreateTide_RevertInvalidAmount() public {
        vm.prank(user);
        vm.expectRevert();
        c.createTide{value: 0.5 ether}(NATIVE_FLOW, 1 ether); // Mismatch
    }

    // ============================================
    // DEPOSIT_TO_TIDE Flow
    // ============================================
    function test_DepositToTide() public {
        vm.prank(user);
        uint256 reqId = c.depositToTide{value: 0.5 ether}(
            42,
            NATIVE_FLOW,
            0.5 ether
        );

        assertEq(reqId, 1);
        assertEq(c.getUserBalance(user, NATIVE_FLOW), 0.5 ether);

        FlowVaultsRequests.Request[] memory reqs = c.getUserRequests(user);
        assertEq(
            uint8(reqs[0].requestType),
            uint8(FlowVaultsRequests.RequestType.DEPOSIT_TO_TIDE)
        );
        assertEq(reqs[0].tideId, 42);
    }

    // ============================================
    // WITHDRAW_FROM_TIDE Flow
    // ============================================
    function test_WithdrawFromTide() public {
        vm.prank(user);
        uint256 reqId = c.withdrawFromTide(42, 0.3 ether);

        assertEq(reqId, 1);
        assertEq(c.getPendingRequestCount(), 1);

        FlowVaultsRequests.Request[] memory reqs = c.getUserRequests(user);
        assertEq(
            uint8(reqs[0].requestType),
            uint8(FlowVaultsRequests.RequestType.WITHDRAW_FROM_TIDE)
        );
        assertEq(reqs[0].amount, 0.3 ether);
    }

    // ============================================
    // CLOSE_TIDE Flow
    // ============================================
    function test_CloseTide() public {
        vm.prank(user);
        uint256 reqId = c.closeTide(42);

        assertEq(reqId, 1);

        FlowVaultsRequests.Request[] memory reqs = c.getUserRequests(user);
        assertEq(
            uint8(reqs[0].requestType),
            uint8(FlowVaultsRequests.RequestType.CLOSE_TIDE)
        );
        assertEq(reqs[0].tideId, 42);
    }

    // ============================================
    // CANCEL_REQUEST Flow
    // ============================================
    function test_CancelRequest() public {
        vm.startPrank(user);
        uint256 reqId = c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether);

        uint256 balBefore = user.balance;
        c.cancelRequest(reqId);

        assertEq(user.balance, balBefore + 1 ether); // Refunded
        assertEq(c.getUserBalance(user, NATIVE_FLOW), 0);
        assertEq(c.getPendingRequestCount(), 0);
        vm.stopPrank();
    }

    function test_CancelRequest_RevertNotOwner() public {
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether);

        vm.prank(makeAddr("other"));
        vm.expectRevert();
        c.cancelRequest(reqId);
    }

    // ============================================
    // COA Operations
    // ============================================
    function test_COA_WithdrawFunds() public {
        vm.prank(user);
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether);

        vm.prank(coa);
        c.withdrawFunds(NATIVE_FLOW, 1 ether);

        assertEq(coa.balance, 1 ether);
    }

    function test_COA_UpdateRequestStatus() public {
        vm.prank(user);
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether);

        vm.prank(coa);
        c.updateRequestStatus(
            1,
            uint8(FlowVaultsRequests.RequestStatus.COMPLETED),
            42,
            "Success"
        );

        FlowVaultsRequests.Request[] memory reqs = c.getUserRequests(user);
        assertEq(
            uint8(reqs[0].status),
            uint8(FlowVaultsRequests.RequestStatus.COMPLETED)
        );
        assertEq(reqs[0].tideId, 42);
        assertEq(c.getPendingRequestCount(), 0); // Removed from pending
    }

    function test_COA_UpdateUserBalance() public {
        vm.prank(user);
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether);

        vm.prank(coa);
        c.updateUserBalance(user, NATIVE_FLOW, 0.5 ether);

        assertEq(c.getUserBalance(user, NATIVE_FLOW), 0.5 ether);
    }

    function test_COA_RevertUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        c.withdrawFunds(NATIVE_FLOW, 1 ether);
    }

    // ============================================
    // Complete Integration Flow
    // ============================================
    function test_FullCreateTideFlow() public {
        // 1. User creates tide
        vm.prank(user);
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether);

        // 2. COA processes
        vm.startPrank(coa);
        c.updateRequestStatus(
            1,
            uint8(FlowVaultsRequests.RequestStatus.PROCESSING),
            0,
            ""
        );
        c.withdrawFunds(NATIVE_FLOW, 1 ether);
        c.updateUserBalance(user, NATIVE_FLOW, 0);
        c.updateRequestStatus(
            1,
            uint8(FlowVaultsRequests.RequestStatus.COMPLETED),
            42,
            "Tide created"
        );
        vm.stopPrank();

        // 3. Verify
        assertEq(c.getUserBalance(user, NATIVE_FLOW), 0);
        assertEq(c.getPendingRequestCount(), 0);
        FlowVaultsRequests.Request[] memory reqs = c.getUserRequests(user);
        assertEq(reqs[0].tideId, 42);
    }

    function test_FullWithdrawFlow() public {
        // User withdraws from existing tide
        vm.prank(user);
        c.withdrawFromTide(42, 0.5 ether);

        // COA processes and sends funds back
        vm.deal(address(c), 0.5 ether);
        vm.startPrank(coa);
        c.updateRequestStatus(
            1,
            uint8(FlowVaultsRequests.RequestStatus.PROCESSING),
            0,
            ""
        );
        // In real scenario, COA would bridge funds back to user's EVM address
        c.updateRequestStatus(
            1,
            uint8(FlowVaultsRequests.RequestStatus.COMPLETED),
            42,
            "Withdrawn"
        );
        vm.stopPrank();

        FlowVaultsRequests.Request[] memory reqs = c.getUserRequests(user);
        assertEq(
            uint8(reqs[0].status),
            uint8(FlowVaultsRequests.RequestStatus.COMPLETED)
        );
    }

    // ============================================
    // Query Functions
    // ============================================
    function test_GetPendingRequestsUnpacked() public {
        vm.startPrank(user);
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether);
        c.depositToTide{value: 0.5 ether}(42, NATIVE_FLOW, 0.5 ether);
        vm.stopPrank();

        (
            uint256[] memory ids,
            address[] memory users,
            ,
            ,
            ,
            uint256[] memory amounts,
            ,
            ,

        ) = c.getPendingRequestsUnpacked(0);

        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(users[0], user);
        assertEq(amounts[0], 1 ether);
    }

    function test_GetPendingRequestsUnpacked_WithLimit() public {
        vm.startPrank(user);
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether);
        c.createTide{value: 2 ether}(NATIVE_FLOW, 2 ether);
        c.createTide{value: 3 ether}(NATIVE_FLOW, 3 ether);
        vm.stopPrank();

        (uint256[] memory ids, , , , , , , , ) = c.getPendingRequestsUnpacked(
            2
        );

        assertEq(ids.length, 2); // Limited to 2
    }
}
