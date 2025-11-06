// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Test.sol";
import "../src/FlowVaultsRequests.sol";

contract FlowVaultsRequestsTest is Test {
    FlowVaultsRequests public flowVaultsRequests;

    address public owner;
    address public user1;
    address public user2;
    address public coa;

    address public constant NATIVE_FLOW =
        0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    event RequestCreated(
        uint256 indexed requestId,
        address indexed user,
        FlowVaultsRequests.RequestType indexed requestType,
        address token,
        uint256 amount
    );

    event RequestProcessed(
        uint256 indexed requestId,
        FlowVaultsRequests.RequestStatus status,
        uint64 tideId
    );

    event FundsWithdrawn(
        address indexed to,
        address indexed token,
        uint256 amount
    );

    event BalanceUpdated(
        address indexed user,
        address indexed token,
        uint256 newBalance
    );

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        coa = makeAddr("coa");

        // Fund test accounts
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
        vm.deal(coa, 10 ether);

        // Deploy FlowVaultsRequests
        flowVaultsRequests = new FlowVaultsRequests(coa);
    }

    // ============================================
    // Request Creation Tests
    // ============================================

    function testcreateRequestCreateTide() public {
        uint256 amount = 1 ether;

        vm.startPrank(user1);

        vm.expectEmit(true, true, true, true);
        emit RequestCreated(
            1,
            user1,
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount
        );

        flowVaultsRequests.createRequest{value: amount}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0 // tideId (0 for CREATE)
        );

        vm.stopPrank();

        // Verify request was created
        FlowVaultsRequests.Request[] memory requests = flowVaultsRequests
            .getUserRequests(user1);
        assertEq(requests.length, 1);
        assertEq(requests[0].id, 1);
        assertEq(requests[0].user, user1);
        assertEq(
            uint8(requests[0].requestType),
            uint8(FlowVaultsRequests.RequestType.CREATE_TIDE)
        );
        assertEq(requests[0].amount, amount);
    }

    function testcreateRequestCloseTide() public {
        uint64 tideId = 42;

        vm.startPrank(user1);

        vm.expectEmit(true, true, true, true);
        emit RequestCreated(
            1,
            user1,
            FlowVaultsRequests.RequestType.CLOSE_TIDE,
            NATIVE_FLOW,
            0
        );

        flowVaultsRequests.createRequest(
            FlowVaultsRequests.RequestType.CLOSE_TIDE,
            NATIVE_FLOW,
            0, // amount not needed for close
            tideId
        );

        vm.stopPrank();

        FlowVaultsRequests.Request[] memory requests = flowVaultsRequests
            .getUserRequests(user1);
        assertEq(requests.length, 1);
        assertEq(requests[0].tideId, tideId);
        assertEq(
            uint8(requests[0].requestType),
            uint8(FlowVaultsRequests.RequestType.CLOSE_TIDE)
        );
    }

    function test_RevertWhencreateRequestWithoutValue() public {
        uint256 amount = 1 ether;

        vm.startPrank(user1);

        vm.expectRevert("FlowVaultsRequests: incorrect native token amount");
        flowVaultsRequests.createRequest(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        ); // No value sent

        vm.stopPrank();
    }

    function test_RevertWhencreateRequestWithMismatchedValue() public {
        uint256 amount = 1 ether;

        vm.startPrank(user1);

        vm.expectRevert("FlowVaultsRequests: incorrect native token amount");
        flowVaultsRequests.createRequest{value: 0.5 ether}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        );

        vm.stopPrank();
    }

    // ============================================
    // Balance Tracking Tests
    // ============================================

    function test_TrackUserBalance() public {
        uint256 amount = 1 ether;

        vm.startPrank(user1);
        flowVaultsRequests.createRequest{value: amount}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        );
        vm.stopPrank();

        uint256 balance = flowVaultsRequests.getUserBalance(user1, NATIVE_FLOW);
        assertEq(balance, amount);
    }

    function test_AccumulateBalance() public {
        uint256 amount1 = 1 ether;
        uint256 amount2 = 2 ether;

        vm.startPrank(user1);

        flowVaultsRequests.createRequest{value: amount1}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount1,
            0
        );

        flowVaultsRequests.createRequest{value: amount2}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount2,
            0
        );

        vm.stopPrank();

        uint256 balance = flowVaultsRequests.getUserBalance(user1, NATIVE_FLOW);
        assertEq(balance, amount1 + amount2);
    }

    function test_IncrementRequestId() public {
        uint256 amount = 1 ether;

        vm.prank(user1);
        flowVaultsRequests.createRequest{value: amount}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        );

        vm.prank(user2);
        flowVaultsRequests.createRequest{value: amount}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        );

        FlowVaultsRequests.Request[] memory user1Requests = flowVaultsRequests
            .getUserRequests(user1);
        FlowVaultsRequests.Request[] memory user2Requests = flowVaultsRequests
            .getUserRequests(user2);

        assertEq(user1Requests[0].id, 1);
        assertEq(user2Requests[0].id, 2);
    }

    // ============================================
    // COA Operations Tests
    // ============================================

    function test_COACanWithdrawFunds() public {
        uint256 amount = 1 ether;

        // User creates request
        vm.prank(user1);
        flowVaultsRequests.createRequest{value: amount}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        );

        // COA withdraws
        uint256 coaBalanceBefore = coa.balance;

        vm.startPrank(coa);

        vm.expectEmit(true, true, false, true);
        emit FundsWithdrawn(coa, NATIVE_FLOW, amount);

        flowVaultsRequests.withdrawFunds(NATIVE_FLOW, amount);

        vm.stopPrank();

        uint256 coaBalanceAfter = coa.balance;
        assertEq(coaBalanceAfter - coaBalanceBefore, amount);
    }

    function test_RevertWhen_NonCOAWithdraws() public {
        uint256 amount = 1 ether;

        vm.prank(user1);
        flowVaultsRequests.createRequest{value: amount}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        );

        vm.startPrank(user2);

        vm.expectRevert("FlowVaultsRequests: caller is not authorized COA");
        flowVaultsRequests.withdrawFunds(NATIVE_FLOW, amount);

        vm.stopPrank();
    }

    function test_COACanUpdateRequestStatus() public {
        uint256 amount = 1 ether;
        uint64 tideId = 42;

        vm.prank(user1);
        flowVaultsRequests.createRequest{value: amount}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        );

        vm.startPrank(coa);

        vm.expectEmit(true, false, false, true);
        emit RequestProcessed(
            1,
            FlowVaultsRequests.RequestStatus.COMPLETED,
            tideId
        );

        flowVaultsRequests.updateRequestStatus(
            1,
            FlowVaultsRequests.RequestStatus.COMPLETED,
            tideId
        );

        vm.stopPrank();

        FlowVaultsRequests.Request[] memory requests = flowVaultsRequests
            .getUserRequests(user1);
        assertEq(
            uint8(requests[0].status),
            uint8(FlowVaultsRequests.RequestStatus.COMPLETED)
        );
        assertEq(requests[0].tideId, tideId);
    }

    function test_RevertWhen_NonCOAUpdatesStatus() public {
        uint256 amount = 1 ether;

        vm.prank(user1);
        flowVaultsRequests.createRequest{value: amount}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        );

        vm.startPrank(user2);

        vm.expectRevert("FlowVaultsRequests: caller is not authorized COA");
        flowVaultsRequests.updateRequestStatus(
            1,
            FlowVaultsRequests.RequestStatus.COMPLETED,
            42
        );

        vm.stopPrank();
    }

    function test_COACanUpdateUserBalance() public {
        uint256 amount = 1 ether;
        uint256 newBalance = 0.5 ether;

        vm.prank(user1);
        flowVaultsRequests.createRequest{value: amount}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        );

        vm.startPrank(coa);

        vm.expectEmit(true, true, false, true);
        emit BalanceUpdated(user1, NATIVE_FLOW, newBalance);

        flowVaultsRequests.updateUserBalance(user1, NATIVE_FLOW, newBalance);

        vm.stopPrank();

        uint256 balance = flowVaultsRequests.getUserBalance(user1, NATIVE_FLOW);
        assertEq(balance, newBalance);
    }

    // ============================================
    // Pending Requests Tests
    // ============================================

    function test_TrackPendingRequests() public {
        uint256 amount = 1 ether;

        vm.prank(user1);
        flowVaultsRequests.createRequest{value: amount}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        );

        uint256[] memory pendingIds = flowVaultsRequests.getPendingRequestIds();
        assertEq(pendingIds.length, 1);
        assertEq(pendingIds[0], 1);
    }

    function test_RemoveFromPendingWhenCompleted() public {
        uint256 amount = 1 ether;

        vm.prank(user1);
        flowVaultsRequests.createRequest{value: amount}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        );

        vm.prank(coa);
        flowVaultsRequests.updateRequestStatus(
            1,
            FlowVaultsRequests.RequestStatus.COMPLETED,
            42
        );

        uint256[] memory pendingIds = flowVaultsRequests.getPendingRequestIds();
        assertEq(pendingIds.length, 0);
    }

    function test_MultiplePendingRequests() public {
        uint256 amount = 1 ether;

        vm.startPrank(user1);
        flowVaultsRequests.createRequest{value: amount}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        );
        flowVaultsRequests.createRequest{value: amount}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        );
        vm.stopPrank();

        uint256[] memory pendingIds = flowVaultsRequests.getPendingRequestIds();
        assertEq(pendingIds.length, 2);
        assertEq(pendingIds[0], 1);
        assertEq(pendingIds[1], 2);
    }

    // ============================================
    // Helper Functions Tests
    // ============================================

    function test_IsNativeFlow() public view {
        assertTrue(flowVaultsRequests.isNativeFlow(NATIVE_FLOW));
        assertFalse(flowVaultsRequests.isNativeFlow(address(0)));
        assertFalse(flowVaultsRequests.isNativeFlow(user1));
    }

    function test_GetUserRequests() public {
        uint256 amount = 1 ether;

        vm.startPrank(user1);
        flowVaultsRequests.createRequest{value: amount}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        );
        flowVaultsRequests.createRequest(
            FlowVaultsRequests.RequestType.CLOSE_TIDE,
            NATIVE_FLOW,
            0,
            42
        );
        vm.stopPrank();

        FlowVaultsRequests.Request[] memory requests = flowVaultsRequests
            .getUserRequests(user1);
        assertEq(requests.length, 2);
        assertEq(
            uint8(requests[0].requestType),
            uint8(FlowVaultsRequests.RequestType.CREATE_TIDE)
        );
        assertEq(
            uint8(requests[1].requestType),
            uint8(FlowVaultsRequests.RequestType.CLOSE_TIDE)
        );
    }

    // ============================================
    // Integration Scenario Tests
    // ============================================

    function test_CompleteCreateTideFlow() public {
        uint256 amount = 1 ether;
        uint64 tideId = 42;

        // 1. User creates request
        vm.prank(user1);
        flowVaultsRequests.createRequest{value: amount}(
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            amount,
            0
        );

        // Verify initial state
        assertEq(flowVaultsRequests.getUserBalance(user1, NATIVE_FLOW), amount);
        uint256[] memory pending = flowVaultsRequests.getPendingRequestIds();
        assertEq(pending.length, 1);

        // 2. COA marks as processing
        vm.prank(coa);
        flowVaultsRequests.updateRequestStatus(
            1,
            FlowVaultsRequests.RequestStatus.PROCESSING,
            0
        );

        // 3. COA withdraws funds
        vm.prank(coa);
        flowVaultsRequests.withdrawFunds(NATIVE_FLOW, amount);

        // 4. COA updates balance to 0 (funds now in Cadence)
        vm.prank(coa);
        flowVaultsRequests.updateUserBalance(user1, NATIVE_FLOW, 0);

        // 5. COA marks as completed with tide ID
        vm.prank(coa);
        flowVaultsRequests.updateRequestStatus(
            1,
            FlowVaultsRequests.RequestStatus.COMPLETED,
            tideId
        );

        // Verify final state
        assertEq(flowVaultsRequests.getUserBalance(user1, NATIVE_FLOW), 0);
        pending = flowVaultsRequests.getPendingRequestIds();
        assertEq(pending.length, 0);

        FlowVaultsRequests.Request[] memory requests = flowVaultsRequests
            .getUserRequests(user1);
        assertEq(
            uint8(requests[0].status),
            uint8(FlowVaultsRequests.RequestStatus.COMPLETED)
        );
        assertEq(requests[0].tideId, tideId);
    }

    function test_CompleteCloseTideFlow() public {
        uint64 tideId = 42;
        uint256 returnAmount = 1.5 ether; // User gets back more than deposited (yield!)

        // 1. User creates close request
        vm.prank(user1);
        flowVaultsRequests.createRequest(
            FlowVaultsRequests.RequestType.CLOSE_TIDE,
            NATIVE_FLOW,
            0,
            tideId
        );

        // 2. COA marks as processing
        vm.prank(coa);
        flowVaultsRequests.updateRequestStatus(
            1,
            FlowVaultsRequests.RequestStatus.PROCESSING,
            0
        );

        // 3. COA receives funds from Cadence (simulate)
        vm.deal(address(flowVaultsRequests), returnAmount);

        // 4. COA marks as completed
        vm.prank(coa);
        flowVaultsRequests.updateRequestStatus(
            1,
            FlowVaultsRequests.RequestStatus.COMPLETED,
            tideId
        );

        // Verify
        FlowVaultsRequests.Request[] memory requests = flowVaultsRequests
            .getUserRequests(user1);
        assertEq(
            uint8(requests[0].status),
            uint8(FlowVaultsRequests.RequestStatus.COMPLETED)
        );
    }
}
