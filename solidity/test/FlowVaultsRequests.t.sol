// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import "forge-std/Test.sol";
import "../src/FlowVaultsRequests.sol";

contract FlowVaultsRequestsTest is Test {
    FlowVaultsRequests public c; // Short name for brevity
    address user = makeAddr("user");
    address coa = makeAddr("coa");
    address constant NATIVE_FLOW = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    // Test vault and strategy identifiers for testnet
    string constant VAULT_IDENTIFIER = "A.7e60df042a9c0868.FlowToken.Vault";
    string constant STRATEGY_IDENTIFIER =
        "A.3bda2f90274dbc9b.FlowVaultsStrategies.TracerStrategy";

    // Event declarations for testing
    event RequestCreated(
        uint256 indexed requestId,
        address indexed user,
        FlowVaultsRequests.RequestType requestType,
        address indexed tokenAddress,
        uint256 amount,
        uint64 tideId
    );
    event BalanceUpdated(
        address indexed user,
        address indexed tokenAddress,
        uint256 newBalance
    );
    event RequestProcessed(
        uint256 indexed requestId,
        FlowVaultsRequests.RequestStatus status,
        uint64 tideId,
        string message
    );
    event RequestCancelled(
        uint256 indexed requestId,
        address indexed user,
        uint256 refundAmount
    );
    event FundsWithdrawn(
        address indexed to,
        address indexed tokenAddress,
        uint256 amount
    );
    event AuthorizedCOAUpdated(address indexed oldCOA, address indexed newCOA);

    function setUp() public {
        vm.deal(user, 100 ether);
        c = new FlowVaultsRequests(coa);
    }

    // ============================================
    // 1. USER REQUEST CREATION TESTS
    // ============================================

    // CREATE_TIDE Tests
    // ============================================
    function test_CreateTide() public {
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

        assertEq(reqId, 1);
        assertEq(c.getUserBalance(user, NATIVE_FLOW), 1 ether);
        assertEq(c.getPendingRequestCount(), 1);

        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(
            uint8(req.requestType),
            uint8(FlowVaultsRequests.RequestType.CREATE_TIDE)
        );
    }

    function test_CreateTide_RevertZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(
            FlowVaultsRequests.AmountMustBeGreaterThanZero.selector
        );
        c.createTide{value: 0}(
            NATIVE_FLOW,
            0,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );
    }

    function test_CreateTide_RevertMsgValueMismatch() public {
        vm.prank(user);
        vm.expectRevert(FlowVaultsRequests.MsgValueMustEqualAmount.selector);
        c.createTide{value: 0.5 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        ); // Mismatch
    }

    // DEPOSIT_TO_TIDE Tests
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

        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(
            uint8(req.requestType),
            uint8(FlowVaultsRequests.RequestType.DEPOSIT_TO_TIDE)
        );
        assertEq(req.tideId, 42);
    }

    function test_DepositToTide_InvalidTideId() public {
        vm.prank(user);
        vm.expectRevert(FlowVaultsRequests.InvalidTideId.selector);
        c.depositToTide{value: 1 ether}(0, NATIVE_FLOW, 1 ether);
    }

    // WITHDRAW_FROM_TIDE Tests
    // ============================================
    function test_WithdrawFromTide() public {
        vm.prank(user);
        uint256 reqId = c.withdrawFromTide(42, 0.3 ether);

        assertEq(reqId, 1);
        assertEq(c.getPendingRequestCount(), 1);

        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(
            uint8(req.requestType),
            uint8(FlowVaultsRequests.RequestType.WITHDRAW_FROM_TIDE)
        );
        assertEq(req.amount, 0.3 ether);
    }

    // CLOSE_TIDE Tests
    // ============================================
    function test_CloseTide() public {
        vm.prank(user);
        uint256 reqId = c.closeTide(42);

        assertEq(reqId, 1);

        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(
            uint8(req.requestType),
            uint8(FlowVaultsRequests.RequestType.CLOSE_TIDE)
        );
        assertEq(req.tideId, 42);
    }

    // ============================================
    // 2. REQUEST CANCELLATION TESTS
    // ============================================
    function test_CancelRequest() public {
        vm.startPrank(user);
        uint256 reqId = c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

        uint256 balBefore = user.balance;
        c.cancelRequest(reqId);

        assertEq(user.balance, balBefore + 1 ether); // Refunded
        assertEq(c.getUserBalance(user, NATIVE_FLOW), 0);
        assertEq(c.getPendingRequestCount(), 0);
        vm.stopPrank();
    }

    function test_CancelRequest_RevertNotOwner() public {
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

        vm.prank(makeAddr("other"));
        vm.expectRevert();
        c.cancelRequest(reqId);
    }

    function test_DoubleRefund_Prevention() public {
        // User creates tide
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

        uint256 balBefore = user.balance;

        // User cancels and gets refund
        vm.prank(user);
        c.cancelRequest(reqId);

        assertEq(user.balance, balBefore + 1 ether);

        // Try to cancel again - should revert because request is now FAILED
        vm.prank(user);
        vm.expectRevert(FlowVaultsRequests.CanOnlyCancelPending.selector);
        c.cancelRequest(reqId);

        // Balance should not have changed
        assertEq(user.balance, balBefore + 1 ether);
    }

    // ============================================
    // 3. COA OPERATIONS TESTS
    // ============================================
    function test_COA_WithdrawFunds() public {
        vm.prank(user);
        c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

        vm.prank(coa);
        c.withdrawFunds(NATIVE_FLOW, 1 ether);

        assertEq(coa.balance, 1 ether);
    }

    function test_COA_UpdateRequestStatus() public {
        vm.prank(user);
        c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

        vm.prank(coa);
        c.updateRequestStatus(
            1,
            uint8(FlowVaultsRequests.RequestStatus.COMPLETED),
            42,
            "Success"
        );

        FlowVaultsRequests.Request memory req = c.getRequest(1);
        assertEq(
            uint8(req.status),
            uint8(FlowVaultsRequests.RequestStatus.COMPLETED)
        );
        assertEq(req.tideId, 42);
        assertEq(c.getPendingRequestCount(), 0); // Removed from pending
    }

    function test_COA_UpdateUserBalance() public {
        vm.prank(user);
        c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

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
    // 4. QUERY & VIEW FUNCTIONS TESTS
    // ============================================

    function test_GetPendingRequestsUnpacked() public {
        vm.startPrank(user);
        c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );
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
        c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );
        c.createTide{value: 2 ether}(
            NATIVE_FLOW,
            2 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );
        c.createTide{value: 3 ether}(
            NATIVE_FLOW,
            3 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );
        vm.stopPrank();

        (uint256[] memory ids, , , , , , , , , , ) = c
            .getPendingRequestsUnpacked(2);

        assertEq(ids.length, 2); // Limited to 2
    }

    // ============================================
    // 5. MULTI-USER SCENARIOS
    // ============================================

    function test_MultipleUsers_SeparateBalances() public {
        address user2 = makeAddr("user2");
        vm.deal(user2, 100 ether);

        // User 1 creates tide
        vm.prank(user);
        c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

        // User 2 creates tide
        vm.prank(user2);
        c.createTide{value: 2 ether}(
            NATIVE_FLOW,
            2 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

        // Verify balances are separate
        assertEq(c.getUserBalance(user, NATIVE_FLOW), 1 ether);
        assertEq(c.getUserBalance(user2, NATIVE_FLOW), 2 ether);

        // Verify requests were created
        FlowVaultsRequests.Request memory req1 = c.getRequest(1);
        FlowVaultsRequests.Request memory req2 = c.getRequest(2);
        assertEq(req1.user, user);
        assertEq(req2.user, user2);
    }

    function test_MultipleUsers_RequestIsolation() public {
        address user2 = makeAddr("user2");
        vm.deal(user2, 100 ether);

        // User 1 creates tide
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

        // User 2 tries to cancel User 1's request
        vm.prank(user2);
        vm.expectRevert(FlowVaultsRequests.NotRequestOwner.selector);
        c.cancelRequest(reqId);

        // Verify request still exists
        assertEq(c.getPendingRequestCount(), 1);
        assertEq(c.getUserBalance(user, NATIVE_FLOW), 1 ether);
    }

    // ============================================
    // 6. BALANCE & ACCOUNTING TESTS
    // ============================================

    function test_UserBalance_AfterFailedRequest() public {
        // User creates tide
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

        // Initial balance
        assertEq(c.getUserBalance(user, NATIVE_FLOW), 1 ether);

        // COA marks request as failed (but doesn't update user balance)
        vm.prank(coa);
        c.updateRequestStatus(
            reqId,
            uint8(FlowVaultsRequests.RequestStatus.FAILED),
            0,
            "Simulated failure"
        );

        // Balance should still be 1 ether (funds remain in contract)
        assertEq(c.getUserBalance(user, NATIVE_FLOW), 1 ether);

        // Verify request is marked as failed
        FlowVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(
            uint8(req.status),
            uint8(FlowVaultsRequests.RequestStatus.FAILED)
        );

        // Request is no longer in pending queue
        assertEq(c.getPendingRequestCount(), 0);

        // Note: In a real scenario, the COA would need to update the user balance
        // to return the funds, or the user would need a different mechanism to reclaim funds
        // from failed requests that were already removed from pending queue
    }

    // ============================================
    // 7. COMPLETE INTEGRATION FLOWS
    // ============================================
    function test_FullCreateTideFlow() public {
        // 1. User creates tide
        vm.prank(user);
        c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

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
        FlowVaultsRequests.Request memory req = c.getRequest(1);
        assertEq(req.tideId, 42);
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

        FlowVaultsRequests.Request memory req = c.getRequest(1);
        assertEq(
            uint8(req.status),
            uint8(FlowVaultsRequests.RequestStatus.COMPLETED)
        );
    }

    // ============================================
    // 8. EVENT EMISSION TESTS
    // ============================================

    function test_Events_RequestCreated() public {
        vm.prank(user);

        vm.expectEmit(true, true, true, true);
        emit RequestCreated(
            1, // requestId
            user,
            FlowVaultsRequests.RequestType.CREATE_TIDE,
            NATIVE_FLOW,
            1 ether,
            0 // tideId
        );

        c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );
    }

    function test_Events_BalanceUpdated() public {
        vm.prank(user);

        vm.expectEmit(true, true, false, true);
        emit BalanceUpdated(user, NATIVE_FLOW, 1 ether);

        c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );
    }

    function test_Events_RequestProcessed() public {
        vm.prank(user);
        c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

        vm.prank(coa);

        vm.expectEmit(true, false, false, true);
        emit RequestProcessed(
            1,
            FlowVaultsRequests.RequestStatus.COMPLETED,
            42,
            "Success"
        );

        c.updateRequestStatus(
            1,
            uint8(FlowVaultsRequests.RequestStatus.COMPLETED),
            42,
            "Success"
        );
    }

    function test_Events_RequestCancelled() public {
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

        vm.prank(user);

        vm.expectEmit(true, true, false, true);
        emit RequestCancelled(reqId, user, 1 ether);

        c.cancelRequest(reqId);
    }

    function test_Events_FundsWithdrawn() public {
        vm.prank(user);
        c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );

        vm.prank(coa);

        vm.expectEmit(true, true, false, true);
        emit FundsWithdrawn(coa, NATIVE_FLOW, 1 ether);

        c.withdrawFunds(NATIVE_FLOW, 1 ether);
    }

    function test_Events_AuthorizedCOAUpdated() public {
        address newCOA = makeAddr("newCOA");

        vm.prank(c.owner());

        vm.expectEmit(true, true, false, true);
        emit AuthorizedCOAUpdated(coa, newCOA);

        c.setAuthorizedCOA(newCOA);
    }

    // ============================================
    // WHITELIST TESTS
    // ============================================

    event WhitelistEnabled(bool enabled);
    event AddressesAddedToWhitelist(address[] addresses);
    event AddressesRemovedFromWhitelist(address[] addresses);

    function test_Whitelist_InitialState() public view {
        assertFalse(c.whitelistEnabled());
        assertFalse(c.whitelisted(user));
    }

    function test_Whitelist_SetEnabled() public {
        vm.prank(c.owner());
        c.setWhitelistEnabled(true);
        assertTrue(c.whitelistEnabled());

        vm.prank(c.owner());
        c.setWhitelistEnabled(false);
        assertFalse(c.whitelistEnabled());
    }

    function test_Whitelist_SetEnabled_RevertNonOwner() public {
        vm.prank(user);
        vm.expectRevert(FlowVaultsRequests.NotOwner.selector);
        c.setWhitelistEnabled(true);
    }

    function test_Whitelist_BatchAdd_SingleAddress() public {
        address[] memory addresses = new address[](1);
        addresses[0] = user;

        vm.prank(c.owner());
        c.batchAddToWhitelist(addresses);

        assertTrue(c.whitelisted(user));
    }

    function test_Whitelist_BatchAdd_MultipleAddresses() public {
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        address[] memory addresses = new address[](3);
        addresses[0] = user;
        addresses[1] = user2;
        addresses[2] = user3;

        vm.prank(c.owner());
        c.batchAddToWhitelist(addresses);

        assertTrue(c.whitelisted(user));
        assertTrue(c.whitelisted(user2));
        assertTrue(c.whitelisted(user3));
    }

    function test_Whitelist_BatchAdd_RevertEmptyArray() public {
        address[] memory addresses = new address[](0);

        vm.prank(c.owner());
        vm.expectRevert(FlowVaultsRequests.EmptyAddressArray.selector);
        c.batchAddToWhitelist(addresses);
    }

    function test_Whitelist_BatchAdd_RevertZeroAddress() public {
        address[] memory addresses = new address[](2);
        addresses[0] = user;
        addresses[1] = address(0);

        vm.prank(c.owner());
        vm.expectRevert(FlowVaultsRequests.CannotWhitelistZeroAddress.selector);
        c.batchAddToWhitelist(addresses);
    }

    function test_Whitelist_BatchAdd_RevertNonOwner() public {
        address[] memory addresses = new address[](1);
        addresses[0] = user;

        vm.prank(user);
        vm.expectRevert(FlowVaultsRequests.NotOwner.selector);
        c.batchAddToWhitelist(addresses);
    }

    function test_Whitelist_BatchRemove_SingleAddress() public {
        // First add user to whitelist
        address[] memory addresses = new address[](1);
        addresses[0] = user;

        vm.prank(c.owner());
        c.batchAddToWhitelist(addresses);
        assertTrue(c.whitelisted(user));

        // Now remove
        vm.prank(c.owner());
        c.batchRemoveFromWhitelist(addresses);
        assertFalse(c.whitelisted(user));
    }

    function test_Whitelist_BatchRemove_MultipleAddresses() public {
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        address[] memory addresses = new address[](3);
        addresses[0] = user;
        addresses[1] = user2;
        addresses[2] = user3;

        // Add all
        vm.prank(c.owner());
        c.batchAddToWhitelist(addresses);

        // Remove all
        vm.prank(c.owner());
        c.batchRemoveFromWhitelist(addresses);

        assertFalse(c.whitelisted(user));
        assertFalse(c.whitelisted(user2));
        assertFalse(c.whitelisted(user3));
    }

    function test_Whitelist_BatchRemove_RevertEmptyArray() public {
        address[] memory addresses = new address[](0);

        vm.prank(c.owner());
        vm.expectRevert(FlowVaultsRequests.EmptyAddressArray.selector);
        c.batchRemoveFromWhitelist(addresses);
    }

    function test_Whitelist_BatchRemove_RevertNonOwner() public {
        address[] memory addresses = new address[](1);
        addresses[0] = user;

        vm.prank(user);
        vm.expectRevert(FlowVaultsRequests.NotOwner.selector);
        c.batchRemoveFromWhitelist(addresses);
    }

    function test_Whitelist_CreateTide_WhitelistDisabled() public {
        // Whitelist is disabled by default, so anyone can create
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );
        assertEq(reqId, 1);
    }

    function test_Whitelist_CreateTide_WhitelistEnabled_NotWhitelisted()
        public
    {
        vm.prank(c.owner());
        c.setWhitelistEnabled(true);

        vm.prank(user);
        vm.expectRevert(FlowVaultsRequests.NotWhitelisted.selector);
        c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );
    }

    function test_Whitelist_CreateTide_WhitelistEnabled_Whitelisted() public {
        // Add user to whitelist
        address[] memory addresses = new address[](1);
        addresses[0] = user;

        vm.prank(c.owner());
        c.batchAddToWhitelist(addresses);

        // Enable whitelist
        vm.prank(c.owner());
        c.setWhitelistEnabled(true);

        // User should be able to create tide
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );
        assertEq(reqId, 1);
    }

    function test_Whitelist_DepositToTide_WhitelistEnabled_NotWhitelisted()
        public
    {
        vm.prank(c.owner());
        c.setWhitelistEnabled(true);

        vm.prank(user);
        vm.expectRevert(FlowVaultsRequests.NotWhitelisted.selector);
        c.depositToTide{value: 1 ether}(42, NATIVE_FLOW, 1 ether);
    }

    function test_Whitelist_DepositToTide_WhitelistEnabled_Whitelisted()
        public
    {
        address[] memory addresses = new address[](1);
        addresses[0] = user;

        vm.prank(c.owner());
        c.batchAddToWhitelist(addresses);

        vm.prank(c.owner());
        c.setWhitelistEnabled(true);

        vm.prank(user);
        uint256 reqId = c.depositToTide{value: 1 ether}(
            42,
            NATIVE_FLOW,
            1 ether
        );
        assertEq(reqId, 1);
    }

    function test_Whitelist_WithdrawFromTide_WhitelistEnabled_NotWhitelisted()
        public
    {
        vm.prank(c.owner());
        c.setWhitelistEnabled(true);

        vm.prank(user);
        vm.expectRevert(FlowVaultsRequests.NotWhitelisted.selector);
        c.withdrawFromTide(42, 1 ether);
    }

    function test_Whitelist_WithdrawFromTide_WhitelistEnabled_Whitelisted()
        public
    {
        address[] memory addresses = new address[](1);
        addresses[0] = user;

        vm.prank(c.owner());
        c.batchAddToWhitelist(addresses);

        vm.prank(c.owner());
        c.setWhitelistEnabled(true);

        vm.prank(user);
        uint256 reqId = c.withdrawFromTide(42, 1 ether);
        assertEq(reqId, 1);
    }

    function test_Whitelist_CloseTide_WhitelistEnabled_NotWhitelisted() public {
        vm.prank(c.owner());
        c.setWhitelistEnabled(true);

        vm.prank(user);
        vm.expectRevert(FlowVaultsRequests.NotWhitelisted.selector);
        c.closeTide(42);
    }

    function test_Whitelist_CloseTide_WhitelistEnabled_Whitelisted() public {
        address[] memory addresses = new address[](1);
        addresses[0] = user;

        vm.prank(c.owner());
        c.batchAddToWhitelist(addresses);

        vm.prank(c.owner());
        c.setWhitelistEnabled(true);

        vm.prank(user);
        uint256 reqId = c.closeTide(42);
        assertEq(reqId, 1);
    }

    function test_Whitelist_RemoveAfterAdd() public {
        address[] memory addresses = new address[](1);
        addresses[0] = user;

        // Add
        vm.prank(c.owner());
        c.batchAddToWhitelist(addresses);
        assertTrue(c.whitelisted(user));

        // Enable whitelist
        vm.prank(c.owner());
        c.setWhitelistEnabled(true);

        // User can create tide
        vm.prank(user);
        uint256 reqId = c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );
        assertEq(reqId, 1);

        // Remove from whitelist
        vm.prank(c.owner());
        c.batchRemoveFromWhitelist(addresses);
        assertFalse(c.whitelisted(user));

        // User cannot create tide anymore
        vm.prank(user);
        vm.expectRevert(FlowVaultsRequests.NotWhitelisted.selector);
        c.createTide{value: 1 ether}(
            NATIVE_FLOW,
            1 ether,
            VAULT_IDENTIFIER,
            STRATEGY_IDENTIFIER
        );
    }

    function test_Whitelist_Events_WhitelistEnabled() public {
        vm.prank(c.owner());

        vm.expectEmit(false, false, false, true);
        emit WhitelistEnabled(true);

        c.setWhitelistEnabled(true);
    }

    function test_Whitelist_Events_AddressesAdded() public {
        address[] memory addresses = new address[](2);
        addresses[0] = user;
        addresses[1] = makeAddr("user2");

        vm.prank(c.owner());

        vm.expectEmit(true, false, false, true);
        emit AddressesAddedToWhitelist(addresses);

        c.batchAddToWhitelist(addresses);
    }

    function test_Whitelist_Events_AddressesRemoved() public {
        address[] memory addresses = new address[](2);
        addresses[0] = user;
        addresses[1] = makeAddr("user2");

        vm.prank(c.owner());
        c.batchAddToWhitelist(addresses);

        vm.prank(c.owner());

        vm.expectEmit(true, false, false, true);
        emit AddressesRemovedFromWhitelist(addresses);

        c.batchRemoveFromWhitelist(addresses);
    }
}
