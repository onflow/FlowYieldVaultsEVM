// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/FlowVaultsRequests.sol";

contract FlowVaultsRequestsTestHelper is FlowVaultsRequests {
    constructor(address coaAddress) FlowVaultsRequests(coaAddress) {}

    function testRegisterTideId(uint64 tideId, address owner) external {
        validTideIds[tideId] = true;
        tideOwners[tideId] = owner;
        tidesByUser[owner].push(tideId);
        userOwnsTide[owner][tideId] = true;
    }
}

contract FlowVaultsRequestsTest is Test {
    FlowVaultsRequestsTestHelper public c;
    address user = makeAddr("user");
    address user2 = makeAddr("user2");
    address coa = makeAddr("coa");
    address constant NATIVE_FLOW = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    // Events for testing (from OpenZeppelin Ownable2Step)
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // Errors from OpenZeppelin Ownable
    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);

    string constant VAULT_ID = "A.0ae53cb6e3f42a79.FlowToken.Vault";
    string constant STRATEGY_ID = "A.045a1763c93006ca.FlowVaultsStrategies.TracerStrategy";

    function setUp() public {
        vm.deal(user, 100 ether);
        vm.deal(user2, 100 ether);
        c = new FlowVaultsRequestsTestHelper(coa);
        c.testRegisterTideId(42, user);
    }

    // ============================================
    // USER REQUEST LIFECYCLE
    // ============================================

    function test_CreateTide() public {
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        assertEq(reqId, 1);
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 1 ether);
        assertEq(c.getPendingRequestCount(), 1);

        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.requestType), uint8(FlowVaultsRequests.RequestType.CREATE_TIDE));
        assertEq(req.user, user);
        assertEq(req.amount, 1 ether);
    }

    function test_DepositToTide() public {
        vm.prank(user);
        uint256 reqId = c.depositToTide{value: 1 ether}(42, NATIVE_FLOW, 1 ether);

        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.requestType), uint8(FlowVaultsRequests.RequestType.DEPOSIT_TO_TIDE));
        assertEq(req.tideId, 42);
    }

    function test_WithdrawFromTide() public {
        vm.prank(user);
        uint256 reqId = c.withdrawFromTide(42, 0.5 ether);

        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.requestType), uint8(FlowVaultsRequests.RequestType.WITHDRAW_FROM_TIDE));
        assertEq(req.amount, 0.5 ether);
    }

    function test_CloseTide() public {
        vm.prank(user);
        uint256 reqId = c.closeTide(42);

        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.requestType), uint8(FlowVaultsRequests.RequestType.CLOSE_TIDE));
        assertEq(req.tideId, 42);
    }

    function test_CancelRequest_RefundsFunds() public {
        vm.startPrank(user);
        uint256 reqId = c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 balBefore = user.balance;

        c.cancelRequest(reqId);
        vm.stopPrank();

        assertEq(user.balance, balBefore + 1 ether);
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 0);
        assertEq(c.getPendingRequestCount(), 0);

        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.status), uint8(FlowVaultsRequests.RequestStatus.FAILED));
    }

    function test_CancelRequest_RevertNotOwner() public {
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user2);
        vm.expectRevert(FlowVaultsRequests.NotRequestOwner.selector);
        c.cancelRequest(reqId);
    }

    function test_CancelRequest_RevertAlreadyCancelled() public {
        vm.startPrank(user);
        uint256 reqId = c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        c.cancelRequest(reqId);

        vm.expectRevert(FlowVaultsRequests.CanOnlyCancelPending.selector);
        c.cancelRequest(reqId);
        vm.stopPrank();
    }

    // ============================================
    // COA PROCESSING - startProcessing & completeProcessing
    // ============================================

    function test_StartProcessing_Success() public {
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 1 ether);

        vm.prank(coa);
        c.startProcessing(reqId);

        // Balance deducted atomically
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 0);

        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.status), uint8(FlowVaultsRequests.RequestStatus.PROCESSING));
    }

    function test_StartProcessing_RevertNotPending() public {
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.startPrank(coa);
        c.startProcessing(reqId);

        vm.expectRevert(FlowVaultsRequests.RequestAlreadyFinalized.selector);
        c.startProcessing(reqId);
        vm.stopPrank();
    }

    function test_StartProcessing_RevertUnauthorized() public {
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(FlowVaultsRequests.NotAuthorizedCOA.selector, user));
        c.startProcessing(reqId);
    }

    function test_CompleteProcessing_Success() public {
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.startPrank(coa);
        c.startProcessing(reqId);
        c.completeProcessing(reqId, true, 100, "Tide created");
        vm.stopPrank();

        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.status), uint8(FlowVaultsRequests.RequestStatus.COMPLETED));
        assertEq(req.tideId, 100);
        assertEq(c.getPendingRequestCount(), 0);

        // Tide ownership registered
        assertEq(c.doesUserOwnTide(user, 100), true);
        assertEq(c.isTideIdValid(100), true);
    }

    function test_CompleteProcessing_FailureRefundsBalance() public {
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.startPrank(coa);
        c.startProcessing(reqId);
        // Balance is now 0
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 0);

        c.completeProcessing(reqId, false, 0, "Cadence error");
        vm.stopPrank();

        // Balance restored on failure
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 1 ether);

        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.status), uint8(FlowVaultsRequests.RequestStatus.FAILED));
    }

    function test_CompleteProcessing_CloseTideRemovesOwnership() public {
        vm.prank(user);
        uint256 reqId = c.closeTide(42);

        vm.startPrank(coa);
        c.startProcessing(reqId);
        c.completeProcessing(reqId, true, 42, "Closed");
        vm.stopPrank();

        assertEq(c.doesUserOwnTide(user, 42), false);
        assertEq(c.isTideIdValid(42), false);
    }

    function test_CompleteProcessing_RevertNotProcessing() public {
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(coa);
        vm.expectRevert(FlowVaultsRequests.RequestAlreadyFinalized.selector);
        c.completeProcessing(reqId, true, 100, "Should fail");
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    function test_SetAuthorizedCOA() public {
        address newCOA = makeAddr("newCOA");

        vm.prank(c.owner());
        c.setAuthorizedCOA(newCOA);

        assertEq(c.authorizedCOA(), newCOA);
    }

    function test_SetAuthorizedCOA_RevertZeroAddress() public {
        vm.prank(c.owner());
        vm.expectRevert(FlowVaultsRequests.InvalidCOAAddress.selector);
        c.setAuthorizedCOA(address(0));
    }

    function test_SetTokenConfig() public {
        address token = makeAddr("token");

        vm.prank(c.owner());
        c.setTokenConfig(token, true, 0.5 ether, false);

        (bool isSupported, uint256 minBalance, bool isNative) = c.allowedTokens(token);
        assertEq(isSupported, true);
        assertEq(minBalance, 0.5 ether);
        assertEq(isNative, false);
    }

    function test_SetMaxPendingRequestsPerUser() public {
        vm.prank(c.owner());
        c.setMaxPendingRequestsPerUser(5);

        assertEq(c.maxPendingRequestsPerUser(), 5);
    }

    function test_MaxPendingRequests_EnforcesLimit() public {
        vm.prank(c.owner());
        c.setMaxPendingRequestsPerUser(2);

        vm.startPrank(user);
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.expectRevert(FlowVaultsRequests.TooManyPendingRequests.selector);
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();
    }

    function test_DropRequests() public {
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 balBefore = user.balance;

        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;

        vm.prank(c.owner());
        c.dropRequests(ids);

        // User refunded
        assertEq(user.balance, balBefore + 1 ether);
        assertEq(c.getPendingRequestCount(), 0);

        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.status), uint8(FlowVaultsRequests.RequestStatus.FAILED));
    }

    // ============================================
    // OWNERSHIP TRANSFER
    // ============================================

    function test_TransferOwnership_TwoStepProcess() public {
        address newOwner = makeAddr("newOwner");
        address originalOwner = c.owner();

        // Step 1: Current owner initiates transfer
        vm.prank(originalOwner);
        c.transferOwnership(newOwner);

        // Owner hasn't changed yet
        assertEq(c.owner(), originalOwner);
        assertEq(c.pendingOwner(), newOwner);

        // Step 2: New owner accepts
        vm.prank(newOwner);
        c.acceptOwnership();

        // Now ownership is transferred
        assertEq(c.owner(), newOwner);
        assertEq(c.pendingOwner(), address(0));
    }

    function test_TransferOwnership_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user));
        c.transferOwnership(makeAddr("newOwner"));
    }

    function test_AcceptOwnership_RevertNotPendingOwner() public {
        vm.prank(c.owner());
        c.transferOwnership(makeAddr("newOwner"));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, user));
        c.acceptOwnership();
    }

    function test_TransferOwnership_NewOwnerHasAdminRights() public {
        address newOwner = makeAddr("newOwner");
        address originalOwner = c.owner();

        vm.prank(originalOwner);
        c.transferOwnership(newOwner);

        vm.prank(newOwner);
        c.acceptOwnership();

        // New owner can perform admin actions
        vm.prank(newOwner);
        c.setMaxPendingRequestsPerUser(99);
        assertEq(c.maxPendingRequestsPerUser(), 99);

        // Old owner cannot
        vm.prank(originalOwner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, originalOwner));
        c.setMaxPendingRequestsPerUser(50);
    }

    // ============================================
    // ACCESS CONTROL
    // ============================================

    function test_Allowlist() public {
        address[] memory addrs = new address[](1);
        addrs[0] = user;

        vm.startPrank(c.owner());
        c.setAllowlistEnabled(true);
        c.batchAddToAllowlist(addrs);
        vm.stopPrank();

        // Allowlisted user can create
        vm.prank(user);
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        // Non-allowlisted user cannot
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(FlowVaultsRequests.NotInAllowlist.selector, user2));
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
    }

    function test_Blocklist() public {
        address[] memory addrs = new address[](1);
        addrs[0] = user;

        vm.startPrank(c.owner());
        c.setBlocklistEnabled(true);
        c.batchAddToBlocklist(addrs);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(FlowVaultsRequests.Blocklisted.selector, user));
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
    }

    function test_BlocklistTakesPrecedence() public {
        address[] memory addrs = new address[](1);
        addrs[0] = user;

        vm.startPrank(c.owner());
        c.setAllowlistEnabled(true);
        c.batchAddToAllowlist(addrs);
        c.setBlocklistEnabled(true);
        c.batchAddToBlocklist(addrs);
        vm.stopPrank();

        // User is both allowlisted AND blocklisted - blocklist wins
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(FlowVaultsRequests.Blocklisted.selector, user));
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
    }

    // ============================================
    // VALIDATION
    // ============================================

    function test_CreateTide_RevertZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(FlowVaultsRequests.AmountMustBeGreaterThanZero.selector);
        c.createTide{value: 0}(NATIVE_FLOW, 0, VAULT_ID, STRATEGY_ID);
    }

    function test_CreateTide_RevertMsgValueMismatch() public {
        vm.prank(user);
        vm.expectRevert(FlowVaultsRequests.MsgValueMustEqualAmount.selector);
        c.createTide{value: 0.5 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
    }

    function test_CreateTide_RevertBelowMinimum() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                FlowVaultsRequests.BelowMinimumBalance.selector,
                NATIVE_FLOW,
                0.5 ether,
                1 ether
            )
        );
        c.createTide{value: 0.5 ether}(NATIVE_FLOW, 0.5 ether, VAULT_ID, STRATEGY_ID);
    }

    function test_DepositToTide_RevertInvalidTideId() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(FlowVaultsRequests.InvalidTideId.selector, 999, user));
        c.depositToTide{value: 1 ether}(999, NATIVE_FLOW, 1 ether);
    }

    function test_DepositToTide_RevertNotOwner() public {
        // Tide 42 is owned by user, not user2
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(FlowVaultsRequests.InvalidTideId.selector, 42, user2));
        c.depositToTide{value: 1 ether}(42, NATIVE_FLOW, 1 ether);
    }

    // ============================================
    // MULTI-USER ISOLATION
    // ============================================

    function test_UserBalancesAreSeparate() public {
        vm.prank(user);
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user2);
        c.createTide{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);

        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 1 ether);
        assertEq(c.getUserPendingBalance(user2, NATIVE_FLOW), 2 ether);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    function test_GetPendingRequestsUnpacked() public {
        vm.startPrank(user);
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        c.depositToTide{value: 2 ether}(42, NATIVE_FLOW, 2 ether);
        vm.stopPrank();

        (
            uint256[] memory ids,
            address[] memory users,
            uint8[] memory requestTypes,
            ,
            ,
            uint256[] memory amounts,
            ,
            ,
            ,
            ,

        ) = c.getPendingRequestsUnpacked(0, 0);

        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
        assertEq(users[0], user);
        assertEq(amounts[0], 1 ether);
        assertEq(amounts[1], 2 ether);
        assertEq(requestTypes[0], uint8(FlowVaultsRequests.RequestType.CREATE_TIDE));
        assertEq(requestTypes[1], uint8(FlowVaultsRequests.RequestType.DEPOSIT_TO_TIDE));
    }

    function test_GetPendingRequestsUnpacked_Pagination() public {
        vm.startPrank(user);
        c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        c.createTide{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);
        c.createTide{value: 3 ether}(NATIVE_FLOW, 3 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        // Get first 2
        (uint256[] memory ids, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);

        // Get starting from index 1
        (uint256[] memory ids2, , , , , , , , , , ) = c.getPendingRequestsUnpacked(1, 2);
        assertEq(ids2.length, 2);
        assertEq(ids2[0], 2);
        assertEq(ids2[1], 3);
    }

    // ============================================
    // INTEGRATION: FULL LIFECYCLE
    // ============================================

    function test_FullCreateTideLifecycle() public {
        // 1. User creates tide
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 1 ether);

        // 2. COA starts processing (deducts balance atomically)
        vm.prank(coa);
        c.startProcessing(reqId);
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 0);

        // 3. COA completes processing (funds are bridged via COA in Cadence)
        vm.prank(coa);
        c.completeProcessing(reqId, true, 100, "Tide created");

        // Verify final state
        assertEq(c.getPendingRequestCount(), 0);
        assertEq(c.doesUserOwnTide(user, 100), true);

        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.status), uint8(FlowVaultsRequests.RequestStatus.COMPLETED));
        assertEq(req.tideId, 100);
    }

    function test_FullWithdrawLifecycle() public {
        // User withdraws from existing tide
        vm.prank(user);
        uint256 reqId = c.withdrawFromTide(42, 0.5 ether);

        // COA processes
        vm.startPrank(coa);
        c.startProcessing(reqId);
        c.completeProcessing(reqId, true, 42, "Withdrawn");
        vm.stopPrank();

        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.status), uint8(FlowVaultsRequests.RequestStatus.COMPLETED));
    }
}
