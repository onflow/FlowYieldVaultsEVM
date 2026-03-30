// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import "../src/FlowYieldVaultsRequests.sol";

contract MockDAI is ERC20 {
    constructor() ERC20("Mock DAI", "DAI") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FlowYieldVaultsRequestsTestHelper is FlowYieldVaultsRequests {
    constructor(address coaAddress, address wflowAddress) FlowYieldVaultsRequests(coaAddress, wflowAddress) {}

    function testRegisterYieldVaultId(uint64 yieldVaultId, address owner, address tokenAddress) external {
        validYieldVaultIds[yieldVaultId] = true;
        yieldVaultOwners[yieldVaultId] = owner;
        yieldVaultTokens[yieldVaultId] = tokenAddress;
        // Track index for O(1) removal (matches _registerYieldVault behavior)
        _yieldVaultIndexInUserArray[owner][yieldVaultId] = yieldVaultsByUser[owner].length;
        yieldVaultsByUser[owner].push(yieldVaultId);
        userOwnsYieldVault[owner][yieldVaultId] = true;
    }
}

contract FlowYieldVaultsRequestsTest is Test {
    FlowYieldVaultsRequestsTestHelper public c;
    address user = makeAddr("user");
    address user2 = makeAddr("user2");
    address coa = makeAddr("coa");
    address constant NATIVE_FLOW = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    address constant WFLOW = 0xd3bF53DAC106A0290B0483EcBC89d40FcC961f3e;

    // Events for testing (from OpenZeppelin Ownable2Step)
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // Events for testing (from FlowYieldVaultsRequests)
    event BalanceUpdated(address indexed user, address indexed tokenAddress, uint256 newBalance);
    event RefundClaimed(address indexed user, address indexed tokenAddress, uint256 amount);
    event TokensRecovered(address indexed to, address indexed tokenAddress, uint256 amount);

    // Errors from OpenZeppelin Ownable
    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);

    string constant VAULT_ID = "A.0ae53cb6e3f42a79.FlowToken.Vault";
    string constant STRATEGY_ID = "A.045a1763c93006ca.MockStrategies.TracerStrategy";

    MockDAI dai;

    function setUp() public {
        vm.deal(user, 100 ether);
        vm.deal(user2, 100 ether);
        c = new FlowYieldVaultsRequestsTestHelper(coa, WFLOW);
        c.testRegisterYieldVaultId(42, user, NATIVE_FLOW);

        dai = new MockDAI();
        dai.mint(user2, 1 ether);
    }

    function _startProcessingBatch(uint256 requestId) internal {
        uint256[] memory successfulRequestIds = new uint256[](1);
        successfulRequestIds[0] = requestId;
        c.startProcessingBatch(successfulRequestIds, new uint256[](0));
    }

    // ============================================
    // USER REQUEST LIFECYCLE
    // ============================================

    function test_CreateYieldVault() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        assertEq(reqId, 1);
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 1 ether);
        assertEq(c.getPendingRequestCount(), 1);

        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.requestType), uint8(FlowYieldVaultsRequests.RequestType.CREATE_YIELDVAULT));
        assertEq(req.user, user);
        assertEq(req.amount, 1 ether);
    }

    function test_CreateYieldVault_UsesSentinelYieldVaultIdPlaceholder() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        uint64 sentinelYieldVaultId = c.NO_YIELDVAULT_ID();
        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(
            req.yieldVaultId,
            sentinelYieldVaultId,
            "CREATE should start with NO_YIELDVAULT_ID"
        );

        vm.startPrank(coa);
        _startProcessingBatch(reqId);
        vm.expectRevert(
            FlowYieldVaultsRequests.CannotRegisterSentinelYieldVaultId.selector
        );
        c.completeProcessing(
            reqId,
            true,
            sentinelYieldVaultId,
            "Invalid yieldVaultId"
        );
        vm.stopPrank();
    }

    function test_CreateYieldVault_CanRegisterZeroYieldVaultId() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.startPrank(coa);
        _startProcessingBatch(reqId);
        c.completeProcessing(reqId, true, 0, "YieldVault 0 created");
        vm.stopPrank();

        assertTrue(c.isYieldVaultIdValid(0), "YieldVault ID 0 should be valid");
        assertTrue(c.doesUserOwnYieldVault(user, 0), "User should own YieldVault 0");
    }

    function test_DepositToYieldVault() public {
        vm.prank(user);
        uint256 reqId = c.depositToYieldVault{value: 1 ether}(42, NATIVE_FLOW, 1 ether);

        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.requestType), uint8(FlowYieldVaultsRequests.RequestType.DEPOSIT_TO_YIELDVAULT));
        assertEq(req.yieldVaultId, 42);
        assertEq(req.tokenAddress, NATIVE_FLOW);
    }

    function test_DepositToYieldVault_RevertTokenMismatch() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                FlowYieldVaultsRequests.YieldVaultTokenMismatch.selector,
                uint64(42),
                NATIVE_FLOW,
                WFLOW
            )
        );
        c.depositToYieldVault(42, WFLOW, 1 ether);
    }

    function test_WithdrawFromYieldVault() public {
        vm.prank(user);
        uint256 reqId = c.withdrawFromYieldVault(42, 0.5 ether);

        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.requestType), uint8(FlowYieldVaultsRequests.RequestType.WITHDRAW_FROM_YIELDVAULT));
        assertEq(req.amount, 0.5 ether);
        assertEq(req.tokenAddress, NATIVE_FLOW);
    }

    function test_WithdrawFromYieldVault_UsesStoredToken() public {
        c.testRegisterYieldVaultId(43, user, WFLOW);

        vm.prank(user);
        uint256 reqId = c.withdrawFromYieldVault(43, 0.5 ether);

        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(req.tokenAddress, WFLOW);
    }

    function test_CloseYieldVault() public {
        vm.prank(user);
        uint256 reqId = c.closeYieldVault(42);

        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.requestType), uint8(FlowYieldVaultsRequests.RequestType.CLOSE_YIELDVAULT));
        assertEq(req.yieldVaultId, 42);
        assertEq(req.tokenAddress, NATIVE_FLOW);
    }

    function test_CloseYieldVault_UsesStoredToken() public {
        c.testRegisterYieldVaultId(44, user, WFLOW);

        vm.prank(user);
        uint256 reqId = c.closeYieldVault(44);

        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(req.tokenAddress, WFLOW);
    }

    function test_CancelRequest_RefundsFunds() public {
        vm.startPrank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 balBefore = user.balance;

        c.cancelRequest(reqId);

        // Pull pattern: funds moved from pendingUserBalances to claimableRefunds
        assertEq(user.balance, balBefore); // No direct transfer
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 0); // Escrowed balance cleared
        assertEq(c.getClaimableRefund(user, NATIVE_FLOW), 1 ether); // Funds claimable
        assertEq(c.getPendingRequestCount(), 0);

        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.FAILED));

        // User claims refund
        c.claimRefund(NATIVE_FLOW);
        vm.stopPrank();

        assertEq(user.balance, balBefore + 1 ether); // Now funds received
        assertEq(c.getClaimableRefund(user, NATIVE_FLOW), 0); // Claimable balance cleared
    }

    function test_CancelRequest_RevertNotOwner() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user2);
        vm.expectRevert(FlowYieldVaultsRequests.NotRequestOwner.selector);
        c.cancelRequest(reqId);
    }

    function test_CancelRequest_RevertAlreadyCancelled() public {
        vm.startPrank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        c.cancelRequest(reqId);

        vm.expectRevert(FlowYieldVaultsRequests.CanOnlyCancelPending.selector);
        c.cancelRequest(reqId);
        vm.stopPrank();
    }

    // ============================================
    // CLAIM REFUND
    // ============================================

    function test_ClaimRefund_Success() public {
        // 1. User creates request
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 1 ether);
        assertEq(c.getClaimableRefund(user, NATIVE_FLOW), 0);

        // 2. COA starts processing (moves funds to COA)
        vm.prank(coa);
        _startProcessingBatch(reqId);
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 0);

        // 3. COA fails and returns funds
        uint64 sentinelYieldVaultId = c.NO_YIELDVAULT_ID();
        vm.prank(coa);
        c.completeProcessing{value: 1 ether}(reqId, false, sentinelYieldVaultId, "Failed");

        // 4. User has refund in claimableRefunds (not pendingUserBalances)
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 0);
        assertEq(c.getClaimableRefund(user, NATIVE_FLOW), 1 ether);

        // 5. User claims refund
        uint256 balBefore = user.balance;
        vm.prank(user);
        c.claimRefund(NATIVE_FLOW);

        // 6. Verify funds transferred and claimable balance zeroed
        assertEq(user.balance, balBefore + 1 ether);
        assertEq(c.getClaimableRefund(user, NATIVE_FLOW), 0);
    }

    function test_ClaimRefund_RevertNoRefundAvailable() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(FlowYieldVaultsRequests.NoRefundAvailable.selector, NATIVE_FLOW));
        c.claimRefund(NATIVE_FLOW);
    }

    function test_ClaimRefund_MultipleTokens() public {
        // User has refunds in multiple tokens (simulated via direct balance manipulation in real scenario)
        // For this test, we create two requests and have them both fail

        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);

        // Process and fail
        vm.prank(coa);
        _startProcessingBatch(reqId);
        uint64 sentinelYieldVaultId = c.NO_YIELDVAULT_ID();
        vm.prank(coa);
        c.completeProcessing{value: 2 ether}(reqId, false, sentinelYieldVaultId, "Failed");

        // Claim only NATIVE_FLOW
        uint256 balBefore = user.balance;
        vm.prank(user);
        c.claimRefund(NATIVE_FLOW);

        assertEq(user.balance, balBefore + 2 ether);
        assertEq(c.getClaimableRefund(user, NATIVE_FLOW), 0);
    }

    function test_ClaimRefund_EmitsEvents() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(coa);
        _startProcessingBatch(reqId);
        uint64 sentinelYieldVaultId = c.NO_YIELDVAULT_ID();
        vm.prank(coa);
        c.completeProcessing{value: 1 ether}(reqId, false, sentinelYieldVaultId, "Failed");

        // RefundClaimed is emitted on claim (no BalanceUpdated since we use separate claimableRefunds mapping)
        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit RefundClaimed(user, NATIVE_FLOW, 1 ether);
        c.claimRefund(NATIVE_FLOW);
    }

    // ============================================
    // COA PROCESSING - startProcessingBatch & completeProcessing
    // ============================================

    function test_StartProcessingBatch_Success() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 1 ether);

        vm.prank(coa);
        _startProcessingBatch(reqId);

        // Balance deducted atomically
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 0);

        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.PROCESSING));
    }

    function test_StartProcessingBatch_RevertRequestNotInQueueWhenQueueEmpty() public {
        vm.startPrank(coa);
        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.RequestNotInQueue.selector,
            1
        ));
        _startProcessingBatch(1);
        vm.stopPrank();
    }

    function test_StartProcessingBatch_RevertRequestNotInQueueWhenQueueNonEmpty() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.startPrank(coa);
        uint256[] memory successfulRequestIds = new uint256[](5);
        successfulRequestIds[0] = reqId;
        successfulRequestIds[1] = reqId+2;

        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.RequestNotInQueue.selector,
            reqId+2
        ));
        c.startProcessingBatch(successfulRequestIds, new uint256[](0));
        vm.stopPrank();
    }

    function test_StartProcessingBatch_RevertUnauthorized() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(FlowYieldVaultsRequests.NotAuthorizedCOA.selector, user));
        _startProcessingBatch(reqId);
    }

    function test_StartProcessingBatch_WithMoreRequestIdsThanQueued() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);
        uint256 req3 = c.createYieldVault{value: 3 ether}(NATIVE_FLOW, 3 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        vm.prank(coa);
        uint256[] memory successfulRequestIds = new uint256[](5);
        successfulRequestIds[0] = req1;
        successfulRequestIds[1] = req2;
        successfulRequestIds[2] = req3;
        successfulRequestIds[3] = req3+5;
        successfulRequestIds[4] = req3+10;

        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.RequestNotInQueue.selector,
            req3+5
        ));
        c.startProcessingBatch(successfulRequestIds, new uint256[](0));

        (uint256[] memory requestIds, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(requestIds.length, 3);

        for (uint256 i = 0; i < requestIds.length; i++) {
            FlowYieldVaultsRequests.Request memory req = c.getRequest(successfulRequestIds[i]);
            assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.PENDING));
        }
    }

    function test_StartProcessingBatch_RevertRequestProcessOutOfOrder() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        vm.startPrank(coa);
        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.RequestProcessOutOfOrder.selector,
            req1, // the expected requestId, in the queue head
            req2 // the provided requestId
        ));
        _startProcessingBatch(req2);
        vm.stopPrank();
    }

    function test_StartProcessingBatch_MultipleSuccessfulRequests() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);
        uint256 req3 = c.createYieldVault{value: 3 ether}(NATIVE_FLOW, 3 ether, VAULT_ID, STRATEGY_ID);
        uint256 req4 = c.createYieldVault{value: 4 ether}(NATIVE_FLOW, 4 ether, VAULT_ID, STRATEGY_ID);
        uint256 req5 = c.createYieldVault{value: 5 ether}(NATIVE_FLOW, 5 ether, VAULT_ID, STRATEGY_ID);
        uint256 req6 = c.createYieldVault{value: 6 ether}(NATIVE_FLOW, 6 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        vm.startPrank(coa);
        // First 3 successful, transition to PROCESSING
        uint256[] memory successfulRequestIds = new uint256[](3);
        successfulRequestIds[0] = req1;
        successfulRequestIds[1] = req2;
        successfulRequestIds[2] = req3;
        c.startProcessingBatch(successfulRequestIds, new uint256[](0));

        (uint256[] memory requestIds, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(requestIds.length, 3);

        for (uint256 i = 0; i < successfulRequestIds.length; i++) {
            FlowYieldVaultsRequests.Request memory req = c.getRequest(successfulRequestIds[i]);
            assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.PROCESSING));
        }

        // Remaining 3 successful, transition to PROCESSING
        successfulRequestIds[0] = req4;
        successfulRequestIds[1] = req5;
        successfulRequestIds[2] = req6;
        c.startProcessingBatch(successfulRequestIds, new uint256[](0));

        (requestIds, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(requestIds.length, 0);

        for (uint256 i = 0; i < successfulRequestIds.length; i++) {
            FlowYieldVaultsRequests.Request memory req = c.getRequest(successfulRequestIds[i]);
            assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.PROCESSING));
        }
        vm.stopPrank();
    }

    function test_StartProcessingBatch_WithUserCancellationRace() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);
        uint256 req3 = c.createYieldVault{value: 3 ether}(NATIVE_FLOW, 3 ether, VAULT_ID, STRATEGY_ID);
        c.cancelRequest(req2);
        vm.stopPrank();

        vm.startPrank(coa);
        // First and third requests, transition to PROCESSING
        uint256[] memory successfulRequestIds = new uint256[](2);
        successfulRequestIds[0] = req1;
        successfulRequestIds[1] = req3;
        // Second request, transition to FAILED
        uint256[] memory rejectedRequestIds = new uint256[](1);
        rejectedRequestIds[0] = req2;

        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.RequestNotInQueue.selector,
            req2
        ));
        c.startProcessingBatch(successfulRequestIds, rejectedRequestIds);

        (uint256[] memory requestIds, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(requestIds.length, 2);

        for (uint256 i = 0; i < successfulRequestIds.length; i++) {
            FlowYieldVaultsRequests.Request memory req = c.getRequest(successfulRequestIds[i]);
            assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.PENDING));
        }

        // Try again, without the user-cancelled request
        c.startProcessingBatch(successfulRequestIds, new uint256[](0));

        (requestIds, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(requestIds.length, 0);

        for (uint256 i = 0; i < successfulRequestIds.length; i++) {
            FlowYieldVaultsRequests.Request memory req = c.getRequest(successfulRequestIds[i]);
            assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.PROCESSING));
        }
    }

    function test_StartProcessingBatch_MultipleSuccessfulAndRejectRequests() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);
        uint256 req3 = c.createYieldVault{value: 3 ether}(NATIVE_FLOW, 3 ether, VAULT_ID, STRATEGY_ID);
        uint256 req4 = c.createYieldVault{value: 4 ether}(NATIVE_FLOW, 4 ether, VAULT_ID, STRATEGY_ID);
        uint256 req5 = c.createYieldVault{value: 5 ether}(NATIVE_FLOW, 5 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        vm.prank(coa);
        // 2 successful, 3 rejected
        uint256[] memory successfulRequestIds = new uint256[](2);
        successfulRequestIds[0] = req2;
        successfulRequestIds[1] = req4;
        uint256[] memory rejectedRequestIds = new uint256[](3);
        rejectedRequestIds[0] = req1;
        rejectedRequestIds[1] = req3;
        rejectedRequestIds[2] = req5;
        c.startProcessingBatch(successfulRequestIds, rejectedRequestIds);

        (uint256[] memory requestIds, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(requestIds.length, 0);

        for (uint256 i = 0; i < successfulRequestIds.length; i++) {
            FlowYieldVaultsRequests.Request memory req = c.getRequest(successfulRequestIds[i]);
            assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.PROCESSING));
        }

        for (uint256 i = 0; i < rejectedRequestIds.length; i++) {
            FlowYieldVaultsRequests.Request memory req = c.getRequest(rejectedRequestIds[i]);
            assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.FAILED));
        }
    }

    function test_StartProcessingBatch_MultipleRejectedRequests() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);
        uint256 req3 = c.createYieldVault{value: 3 ether}(NATIVE_FLOW, 3 ether, VAULT_ID, STRATEGY_ID);
        uint256 req4 = c.createYieldVault{value: 4 ether}(NATIVE_FLOW, 4 ether, VAULT_ID, STRATEGY_ID);
        uint256 req5 = c.createYieldVault{value: 5 ether}(NATIVE_FLOW, 5 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        vm.prank(coa);
        // All 5 rejected, transition to FAILED
        uint256[] memory rejectedRequestIds = new uint256[](5);
        rejectedRequestIds[0] = req1;
        rejectedRequestIds[1] = req2;
        rejectedRequestIds[2] = req3;
        rejectedRequestIds[3] = req4;
        rejectedRequestIds[4] = req5;
        c.startProcessingBatch(new uint256[](0), rejectedRequestIds);

        (uint256[] memory requestIds, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(requestIds.length, 0);

        for (uint256 i = 0; i < rejectedRequestIds.length; i++) {
            FlowYieldVaultsRequests.Request memory req = c.getRequest(rejectedRequestIds[i]);
            assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.FAILED));
        }
    }

    function test_StartProcessingBatch_MultipleSuccessfulRequestsRevertRequestProcessOutOfOrder() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);
        uint256 req3 = c.createYieldVault{value: 3 ether}(NATIVE_FLOW, 3 ether, VAULT_ID, STRATEGY_ID);
        uint256 req4 = c.createYieldVault{value: 4 ether}(NATIVE_FLOW, 4 ether, VAULT_ID, STRATEGY_ID);
        uint256 req5 = c.createYieldVault{value: 5 ether}(NATIVE_FLOW, 5 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        vm.prank(coa);
        // 2 successful but out-of-order, 3 rejected
        uint256[] memory successfulRequestIds = new uint256[](2);
        // These are out-of-order
        successfulRequestIds[0] = req4;
        successfulRequestIds[1] = req2;
        uint256[] memory rejectedRequestIds = new uint256[](3);
        rejectedRequestIds[0] = req1;
        rejectedRequestIds[1] = req3;
        rejectedRequestIds[2] = req5;

        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.RequestProcessOutOfOrder.selector,
            req2, // queue[head+1] — the current queue position that doesn't match either input array
            req4  // the first provided requestId, from successfulRequestIds
        ));
        c.startProcessingBatch(successfulRequestIds, rejectedRequestIds);

        (uint256[] memory requestIds, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(requestIds.length, 5);

        for (uint256 i = 0; i < successfulRequestIds.length; i++) {
            FlowYieldVaultsRequests.Request memory req = c.getRequest(successfulRequestIds[i]);
            assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.PENDING));
        }

        for (uint256 i = 0; i < rejectedRequestIds.length; i++) {
            FlowYieldVaultsRequests.Request memory req = c.getRequest(rejectedRequestIds[i]);
            assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.PENDING));
        }
    }

    function test_StartProcessingBatch_MultipleRejectedRequestsOutOfOrder() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);
        uint256 req3 = c.createYieldVault{value: 3 ether}(NATIVE_FLOW, 3 ether, VAULT_ID, STRATEGY_ID);
        uint256 req4 = c.createYieldVault{value: 4 ether}(NATIVE_FLOW, 4 ether, VAULT_ID, STRATEGY_ID);
        uint256 req5 = c.createYieldVault{value: 5 ether}(NATIVE_FLOW, 5 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        vm.prank(coa);
        // 2 successful, 3 rejected but out-of-order
        uint256[] memory successfulRequestIds = new uint256[](2);
        successfulRequestIds[0] = req4;
        successfulRequestIds[1] = req5;
        uint256[] memory rejectedRequestIds = new uint256[](3);
        // These are out-of-order
        rejectedRequestIds[0] = req3;
        rejectedRequestIds[1] = req1;
        rejectedRequestIds[2] = req2;

        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.RequestProcessOutOfOrder.selector,
            req1, // the expected requestId, in the queue head
            req4 // the first provided requestId, from successfulRequestIds
        ));
        c.startProcessingBatch(successfulRequestIds, rejectedRequestIds);

        (uint256[] memory requestIds, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(requestIds.length, 5);

        for (uint256 i = 0; i < successfulRequestIds.length; i++) {
            FlowYieldVaultsRequests.Request memory req = c.getRequest(successfulRequestIds[i]);
            assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.PENDING));
        }

        for (uint256 i = 0; i < rejectedRequestIds.length; i++) {
            FlowYieldVaultsRequests.Request memory req = c.getRequest(rejectedRequestIds[i]);
            assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.PENDING));
        }
    }

    function test_CompleteProcessing_Success() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.startPrank(coa);
        _startProcessingBatch(reqId);
        c.completeProcessing(reqId, true, 100, "YieldVault created");
        vm.stopPrank();

        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.COMPLETED));
        assertEq(req.yieldVaultId, 100);
        assertEq(c.getPendingRequestCount(), 0);

        // YieldVault ownership registered
        assertEq(c.doesUserOwnYieldVault(user, 100), true);
        assertEq(c.isYieldVaultIdValid(100), true);
    }

    function test_CompleteProcessing_FailureRefundsBalance() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.startPrank(coa);
        _startProcessingBatch(reqId);
        // Escrowed balance is now 0 (funds sent to COA)
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 0);
        assertEq(c.getClaimableRefund(user, NATIVE_FLOW), 0);

        // COA must return funds when completing with failure
        c.completeProcessing{value: 1 ether}(reqId, false, c.NO_YIELDVAULT_ID(), "Cadence error");
        vm.stopPrank();

        // Funds go to claimableRefunds (not pendingUserBalances)
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 0);
        assertEq(c.getClaimableRefund(user, NATIVE_FLOW), 1 ether);

        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.FAILED));
    }

    function test_CompleteProcessing_FailureRefundsBalance_DepositToYieldVault() public {
        vm.prank(user);
        uint256 reqId = c.depositToYieldVault{value: 1 ether}(42, NATIVE_FLOW, 1 ether);

        vm.startPrank(coa);
        _startProcessingBatch(reqId);
        // Escrowed balance is now 0 (funds sent to COA)
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 0);
        assertEq(c.getClaimableRefund(user, NATIVE_FLOW), 0);

        // COA must return funds when completing with failure
        c.completeProcessing{value: 1 ether}(reqId, false, 42, "Cadence error");
        vm.stopPrank();

        // Funds go to claimableRefunds (not pendingUserBalances)
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 0);
        assertEq(c.getClaimableRefund(user, NATIVE_FLOW), 1 ether);

        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.requestType), uint8(FlowYieldVaultsRequests.RequestType.DEPOSIT_TO_YIELDVAULT));
        assertEq(req.yieldVaultId, 42);
        assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.FAILED));
    }

    function test_CompleteProcessing_CloseYieldVaultRemovesOwnership() public {
        vm.prank(user);
        uint256 reqId = c.closeYieldVault(42);

        vm.startPrank(coa);
        _startProcessingBatch(reqId);
        c.completeProcessing(reqId, true, 42, "Closed");
        vm.stopPrank();

        assertEq(c.doesUserOwnYieldVault(user, 42), false);
        assertEq(c.isYieldVaultIdValid(42), false);
    }

    function test_CompleteProcessing_RevertNotProcessing() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(coa);
        vm.expectRevert(FlowYieldVaultsRequests.InvalidRequestState.selector);
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
        vm.expectRevert(FlowYieldVaultsRequests.InvalidCOAAddress.selector);
        c.setAuthorizedCOA(address(0));
    }

    function test_Constructor_RevertZeroCOAAddress() public {
        vm.expectRevert(FlowYieldVaultsRequests.InvalidCOAAddress.selector);
        new FlowYieldVaultsRequestsTestHelper(address(0), WFLOW);
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

    function test_SetTokenConfig_RevertZeroMinimumForSupportedToken() public {
        address token = makeAddr("token");

        vm.prank(c.owner());
        vm.expectRevert(FlowYieldVaultsRequests.InvalidMinimumBalance.selector);
        c.setTokenConfig(token, true, 0, false);
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
        c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.expectRevert(FlowYieldVaultsRequests.TooManyPendingRequests.selector);
        c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();
    }

    function test_DropRequests() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 balBefore = user.balance;

        uint256[] memory ids = new uint256[](1);
        ids[0] = reqId;

        vm.prank(c.owner());
        c.dropRequests(ids);

        // Pull pattern: funds moved from pendingUserBalances to claimableRefunds
        assertEq(user.balance, balBefore); // No direct transfer
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 0); // Escrowed balance cleared
        assertEq(c.getClaimableRefund(user, NATIVE_FLOW), 1 ether); // Funds claimable
        assertEq(c.getPendingRequestCount(), 0);

        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.FAILED));

        // User claims refund
        vm.prank(user);
        c.claimRefund(NATIVE_FLOW);

        assertEq(user.balance, balBefore + 1 ether); // Now funds received
        assertEq(c.getClaimableRefund(user, NATIVE_FLOW), 0); // Claimable balance cleared
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
        c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        // Non-allowlisted user cannot
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(FlowYieldVaultsRequests.NotInAllowlist.selector, user2));
        c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
    }

    function test_Blocklist() public {
        address[] memory addrs = new address[](1);
        addrs[0] = user;

        vm.startPrank(c.owner());
        c.setBlocklistEnabled(true);
        c.batchAddToBlocklist(addrs);
        vm.stopPrank();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(FlowYieldVaultsRequests.Blocklisted.selector, user));
        c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
    }

    function test_BatchAddToBlocklist_RevertZeroAddress() public {
        address[] memory addrs = new address[](1);
        addrs[0] = address(0);

        vm.prank(c.owner());
        vm.expectRevert(FlowYieldVaultsRequests.CannotBlocklistZeroAddress.selector);
        c.batchAddToBlocklist(addrs);
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
        vm.expectRevert(abi.encodeWithSelector(FlowYieldVaultsRequests.Blocklisted.selector, user));
        c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
    }

    // ============================================
    // VALIDATION
    // ============================================

    function test_CreateYieldVault_RevertZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(FlowYieldVaultsRequests.AmountMustBeGreaterThanZero.selector);
        c.createYieldVault{value: 0}(NATIVE_FLOW, 0, VAULT_ID, STRATEGY_ID);
    }

    function test_CreateYieldVault_RevertMsgValueMismatch() public {
        vm.prank(user);
        vm.expectRevert(FlowYieldVaultsRequests.MsgValueMustEqualAmount.selector);
        c.createYieldVault{value: 0.5 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
    }

    function test_CreateYieldVault_RevertBelowMinimum() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                FlowYieldVaultsRequests.BelowMinimumBalance.selector,
                NATIVE_FLOW,
                0.5 ether,
                1 ether
            )
        );
        c.createYieldVault{value: 0.5 ether}(NATIVE_FLOW, 0.5 ether, VAULT_ID, STRATEGY_ID);
    }

    function test_DepositToYieldVault_RevertInvalidYieldVaultId() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(FlowYieldVaultsRequests.InvalidYieldVaultId.selector, 999, user));
        c.depositToYieldVault{value: 1 ether}(999, NATIVE_FLOW, 1 ether);
    }

    function test_CreateYieldVault_RevertEmptyVaultIdentifier() public {
        vm.prank(user);
        vm.expectRevert(FlowYieldVaultsRequests.EmptyVaultIdentifier.selector);
        c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, "", STRATEGY_ID);
    }

    function test_CreateYieldVault_RevertEmptyStrategyIdentifier() public {
        vm.prank(user);
        vm.expectRevert(FlowYieldVaultsRequests.EmptyStrategyIdentifier.selector);
        c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, "");
    }

    function test_CreateYieldVault_RevertBothIdentifiersEmpty() public {
        vm.prank(user);
        // Should revert on vaultIdentifier check first
        vm.expectRevert(FlowYieldVaultsRequests.EmptyVaultIdentifier.selector);
        c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, "", "");
    }

    function test_DepositToYieldVault_AnyoneCanDeposit() public {
        // YieldVault 42 is owned by user, but user2 can deposit to it
        vm.prank(user2);
        uint256 reqId = c.depositToYieldVault{value: 1 ether}(42, NATIVE_FLOW, 1 ether);

        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.requestType), uint8(FlowYieldVaultsRequests.RequestType.DEPOSIT_TO_YIELDVAULT));
        assertEq(req.yieldVaultId, 42);
        assertEq(req.user, user2);
        assertEq(req.amount, 1 ether);
        assertEq(c.getUserPendingBalance(user2, NATIVE_FLOW), 1 ether);
    }

    // ============================================
    // MULTI-USER ISOLATION
    // ============================================

    function test_UserBalancesAreSeparate() public {
        vm.prank(user);
        c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user2);
        c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);

        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 1 ether);
        assertEq(c.getUserPendingBalance(user2, NATIVE_FLOW), 2 ether);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    function test_GetPendingRequestsUnpacked() public {
        vm.startPrank(user);
        c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        c.depositToYieldVault{value: 2 ether}(42, NATIVE_FLOW, 2 ether);
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
        assertEq(requestTypes[0], uint8(FlowYieldVaultsRequests.RequestType.CREATE_YIELDVAULT));
        assertEq(requestTypes[1], uint8(FlowYieldVaultsRequests.RequestType.DEPOSIT_TO_YIELDVAULT));
    }

    function test_GetPendingRequestsUnpacked_Pagination() public {
        vm.startPrank(user);
        c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);
        c.createYieldVault{value: 3 ether}(NATIVE_FLOW, 3 ether, VAULT_ID, STRATEGY_ID);
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

    function test_FullCreateYieldVaultLifecycle() public {
        // 1. User creates yieldvault
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 1 ether);

        // 2. COA starts processing (deducts balance atomically)
        vm.prank(coa);
        _startProcessingBatch(reqId);
        assertEq(c.getUserPendingBalance(user, NATIVE_FLOW), 0);

        // 3. COA completes processing (funds are bridged via COA in Cadence)
        vm.prank(coa);
        c.completeProcessing(reqId, true, 100, "YieldVault created");

        // Verify final state
        assertEq(c.getPendingRequestCount(), 0);
        assertEq(c.doesUserOwnYieldVault(user, 100), true);

        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.COMPLETED));
        assertEq(req.yieldVaultId, 100);
    }

    function test_FullWithdrawLifecycle() public {
        // User withdraws from existing yieldvault
        vm.prank(user);
        uint256 reqId = c.withdrawFromYieldVault(42, 0.5 ether);

        // COA processes
        vm.startPrank(coa);
        _startProcessingBatch(reqId);
        c.completeProcessing(reqId, true, 42, "Withdrawn");
        vm.stopPrank();

        FlowYieldVaultsRequests.Request memory req = c.getRequest(reqId);
        assertEq(uint8(req.status), uint8(FlowYieldVaultsRequests.RequestStatus.COMPLETED));
    }

    // ============================================
    // WFLOW SUPPORT
    // ============================================

    function test_WFLOWConfiguredOnDeployment() public {
        // WFLOW should be configured as supported token on deployment
        (bool isSupported, uint256 minBalance, bool isNative) = c.allowedTokens(WFLOW);
        assertEq(isSupported, true, "WFLOW should be supported");
        assertEq(minBalance, 1 ether, "WFLOW minimum balance should be 1 ether");
        assertEq(isNative, false, "WFLOW should not be marked as native");
    }

    function test_WFLOWImmutableAddress() public {
        // WFLOW address should be set correctly
        assertEq(c.WFLOW(), WFLOW);
    }

    function test_DeployWithZeroWFLOWAddress() public {
        // Deploy with address(0) for WFLOW - should work but not configure WFLOW
        FlowYieldVaultsRequestsTestHelper contractNoWflow = new FlowYieldVaultsRequestsTestHelper(coa, address(0));

        // WFLOW at address(0) should NOT be supported
        (bool isSupported, , ) = contractNoWflow.allowedTokens(address(0));
        assertEq(isSupported, false, "address(0) should not be supported as WFLOW");

        // Native FLOW should still be supported
        (bool nativeSupported, , ) = contractNoWflow.allowedTokens(NATIVE_FLOW);
        assertEq(nativeSupported, true, "Native FLOW should still be supported");
    }

    // ============================================
    // FIFO QUEUE OPTIMIZATION TESTS
    // ============================================

    function test_FIFOOrder_MaintainedAfterRemoval() public {
        // Create 5 requests from different users
        vm.prank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user2);
        uint256 req2 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user);
        uint256 req3 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user2);
        uint256 req4 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user);
        uint256 req5 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.startPrank(coa);
        _startProcessingBatch(req1);
        c.completeProcessing(req1, true, 200, "Created");
        vm.stopPrank();

        // Verify FIFO order is maintained: [req2, req3, req4, req5]
        (uint256[] memory ids, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(ids.length, 4, "Should have 4 pending requests");
        assertEq(ids[0], req2, "First should be req2");
        assertEq(ids[1], req3, "Second should be req3");
        assertEq(ids[2], req4, "Third should be req4");
        assertEq(ids[3], req5, "Fourth should be req5");
    }

    function test_FIFOOrder_RemoveFirstElement() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req3 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        // Remove first element
        vm.startPrank(coa);
        _startProcessingBatch(req1);
        c.completeProcessing(req1, true, 100, "Created");
        vm.stopPrank();

        (uint256[] memory ids, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(ids.length, 2);
        assertEq(ids[0], req2, "First should now be req2");
        assertEq(ids[1], req3, "Second should be req3");
    }

    function test_FIFOOrder_RemoveLastElement() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req3 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        // Remove last queue element, by cancelling the last request
        c.cancelRequest(req3);

        (uint256[] memory ids, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(ids.length, 2);
        assertEq(ids[0], req1);
        assertEq(ids[1], req2);
    }

    function test_FIFOOrder_RemoveAllInOrder() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req3 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        // Process in FIFO order
        vm.startPrank(coa);
        _startProcessingBatch(req1);
        c.completeProcessing(req1, true, 100, "Created");

        _startProcessingBatch(req2);
        c.completeProcessing(req2, true, 101, "Created");

        _startProcessingBatch(req3);
        c.completeProcessing(req3, true, 102, "Created");
        vm.stopPrank();

        assertEq(c.getPendingRequestCount(), 0, "All requests should be processed");
    }

    function test_FIFOOrder_RemoveOutOfOrder() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req3 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req4 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        vm.startPrank(coa);
        _startProcessingBatch(req1);
        c.completeProcessing(req1, true, 100, "Created");

        // After removing req1: [req2, req3, req4]
        (uint256[] memory ids1, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(ids1[0], req2);
        assertEq(ids1[1], req3);
        assertEq(ids1[2], req4);

        _startProcessingBatch(req2);
        c.completeProcessing(req2, true, 101, "Created");

        // After removing req2: [req3, req4]
        (uint256[] memory ids2, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(ids2[0], req3);
        assertEq(ids2[1], req4);

        _startProcessingBatch(req3);
        c.completeProcessing(req3, true, 102, "Created");

        // After removing req3: [req4]
        (uint256[] memory ids3, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(ids3.length, 1);
        assertEq(ids3[0], req4);

        _startProcessingBatch(req4);
        c.completeProcessing(req4, true, 103, "Created");
        vm.stopPrank();

        assertEq(c.getPendingRequestCount(), 0);
    }

    // ============================================
    // PER-USER PENDING REQUESTS TESTS
    // ============================================

    function test_GetPendingRequestsByUserUnpacked_SingleUser() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.depositToYieldVault{value: 2 ether}(42, NATIVE_FLOW, 2 ether);
        vm.stopPrank();

        (
            uint256[] memory ids,
            uint8[] memory requestTypes,
            uint8[] memory statuses,
            address[] memory tokenAddresses,
            uint256[] memory amounts,
            uint64[] memory yieldVaultIds,
            uint256[] memory timestamps,
            string[] memory messages,
            string[] memory vaultIdentifiers,
            string[] memory strategyIdentifiers,
            uint256 pendingBalance,
        ) = c.getPendingRequestsByUserUnpacked(user);

        assertEq(ids.length, 2, "User should have 2 pending requests");
        assertEq(ids[0], req1);
        assertEq(ids[1], req2);
        assertEq(requestTypes[0], uint8(FlowYieldVaultsRequests.RequestType.CREATE_YIELDVAULT));
        assertEq(requestTypes[1], uint8(FlowYieldVaultsRequests.RequestType.DEPOSIT_TO_YIELDVAULT));
        assertEq(amounts[0], 1 ether);
        assertEq(amounts[1], 2 ether);
        assertEq(pendingBalance, 3 ether, "Pending balance should be sum of amounts");
    }

    function test_GetPendingRequestsByUserUnpacked_MultipleUsers() public {
        vm.prank(user);
        c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user2);
        c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user);
        c.createYieldVault{value: 3 ether}(NATIVE_FLOW, 3 ether, VAULT_ID, STRATEGY_ID);

        // Check user's requests
        (uint256[] memory userIds, , , , , , , , , , uint256 userBalance, ) = c.getPendingRequestsByUserUnpacked(user);
        assertEq(userIds.length, 2, "User should have 2 requests");
        assertEq(userBalance, 4 ether, "User pending balance should be 4 ether");

        // Check user2's requests
        (uint256[] memory user2Ids, , , , , , , , , , uint256 user2Balance, ) = c.getPendingRequestsByUserUnpacked(user2);
        assertEq(user2Ids.length, 1, "User2 should have 1 request");
        assertEq(user2Balance, 2 ether, "User2 pending balance should be 2 ether");
    }

    function test_GetPendingRequestsByUserUnpacked_EmptyForNewUser() public {
        address newUser = makeAddr("newUser");

        (uint256[] memory ids, , , , , , , , , , uint256 pendingBalance, ) = c.getPendingRequestsByUserUnpacked(newUser);

        assertEq(ids.length, 0, "New user should have no pending requests");
        assertEq(pendingBalance, 0, "New user should have 0 pending balance");
    }

    function test_GetPendingRequestsByUserUnpacked_AfterProcessing() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);
        uint256 req3 = c.createYieldVault{value: 3 ether}(NATIVE_FLOW, 3 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        // Process req2
        vm.startPrank(coa);
        _startProcessingBatch(req1);
        c.completeProcessing(req1, true, 100, "Created");
        vm.stopPrank();

        // User should now have req2 and req3
        (uint256[] memory ids, , , , uint256[] memory amounts, , , , , , uint256 pendingBalance, ) = c.getPendingRequestsByUserUnpacked(user);
        assertEq(ids.length, 2, "User should have 2 remaining requests");
        // Note: Order in user array may change due to swap-and-pop optimization
        assertTrue(ids[0] == req2 || ids[0] == req3, "Should contain req2 or req3");
        assertTrue(ids[1] == req2 || ids[1] == req3, "Should contain req2 or req3");
        assertTrue(ids[0] != ids[1], "Should be different requests");
        assertEq(pendingBalance, 5 ether, "Pending balance should be 5 ether");
    }

    function test_GetPendingRequestsByUserUnpacked_AfterCancel() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);

        // Cancel req1
        c.cancelRequest(req1);
        vm.stopPrank();

        (uint256[] memory ids, , , , , , , , , , uint256 pendingBalance, uint256 claimableRefund) = c.getPendingRequestsByUserUnpacked(user);
        assertEq(ids.length, 1, "User should have 1 remaining request");
        assertEq(ids[0], req2, "Remaining request should be req2");
        // pendingBalance = 2 ether (escrowed for req2 only)
        // claimableRefund = 1 ether (from cancelled req1)
        assertEq(pendingBalance, 2 ether);
        assertEq(claimableRefund, 1 ether);
    }

    // ============================================
    // USER REQUEST INDEX TRACKING TESTS
    // ============================================

    function test_UserRequestIndex_CorrectAfterMultipleOperations() public {
        address user3 = makeAddr("user3");
        vm.deal(user3, 100 ether);

        // Create requests from multiple users interleaved
        vm.prank(user);
        uint256 u1r1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user2);
        uint256 u2r1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user);
        uint256 u1r2 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user3);
        uint256 u3r1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(user);
        uint256 u1r3 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        // Process user's first request (u1r1)
        vm.startPrank(coa);
        _startProcessingBatch(u1r1);
        c.completeProcessing(u1r1, true, 100, "Created");
        vm.stopPrank();

        // Verify user1's remaining requests
        (uint256[] memory u1Ids, , , , , , , , , , , ) = c.getPendingRequestsByUserUnpacked(user);
        assertEq(u1Ids.length, 2, "User1 should have 2 requests");

        // Verify user2's requests unchanged
        (uint256[] memory u2Ids, , , , , , , , , , , ) = c.getPendingRequestsByUserUnpacked(user2);
        assertEq(u2Ids.length, 1, "User2 should have 1 request");
        assertEq(u2Ids[0], u2r1);

        // Verify user3's requests unchanged
        (uint256[] memory u3Ids, , , , , , , , , , , ) = c.getPendingRequestsByUserUnpacked(user3);
        assertEq(u3Ids.length, 1, "User3 should have 1 request");
        assertEq(u3Ids[0], u3r1);
    }

    function test_UserRequestIndex_RemoveAllUserRequests() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        vm.startPrank(coa);
        _startProcessingBatch(req1);
        c.completeProcessing(req1, true, 100, "Created");
        _startProcessingBatch(req2);
        c.completeProcessing(req2, true, 101, "Created");
        vm.stopPrank();

        (uint256[] memory ids, , , , , , , , , , uint256 pendingBalance, ) = c.getPendingRequestsByUserUnpacked(user);
        assertEq(ids.length, 0, "User should have no pending requests");
        assertEq(pendingBalance, 0);
    }

    // ============================================
    // YIELDVAULT INDEX TRACKING TESTS
    // ============================================

    function test_YieldVaultIndex_RegisterAndUnregister() public {
        // Create yieldvault
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.startPrank(coa);
        _startProcessingBatch(reqId);
        c.completeProcessing(reqId, true, 200, "Created");
        vm.stopPrank();

        // Verify yieldvault is registered
        assertEq(c.doesUserOwnYieldVault(user, 200), true);
        uint64[] memory userYieldVaults = c.getYieldVaultIdsForUser(user);
        assertEq(userYieldVaults.length, 2); // 42 from setUp + 200

        // Close yieldvault
        vm.prank(user);
        uint256 closeReqId = c.closeYieldVault(200);

        vm.startPrank(coa);
        _startProcessingBatch(closeReqId);
        c.completeProcessing(closeReqId, true, 200, "Closed");
        vm.stopPrank();

        // Verify yieldvault is unregistered
        assertEq(c.doesUserOwnYieldVault(user, 200), false);
        userYieldVaults = c.getYieldVaultIdsForUser(user);
        assertEq(userYieldVaults.length, 1); // Only 42 remains
        assertEq(userYieldVaults[0], 42);
    }

    function test_YieldVaultIndex_MultipleYieldVaults() public {
        // Create 3 yieldvaults
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req3 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        vm.startPrank(coa);
        _startProcessingBatch(req1);
        c.completeProcessing(req1, true, 100, "Created");
        _startProcessingBatch(req2);
        c.completeProcessing(req2, true, 101, "Created");
        _startProcessingBatch(req3);
        c.completeProcessing(req3, true, 102, "Created");
        vm.stopPrank();

        // User now has yieldvaults: 42, 100, 101, 102
        uint64[] memory userYieldVaults = c.getYieldVaultIdsForUser(user);
        assertEq(userYieldVaults.length, 4);

        // Close middle yieldvault (101)
        vm.prank(user);
        uint256 closeReq = c.closeYieldVault(101);

        vm.startPrank(coa);
        _startProcessingBatch(closeReq);
        c.completeProcessing(closeReq, true, 101, "Closed");
        vm.stopPrank();

        // Verify 101 is removed
        assertEq(c.doesUserOwnYieldVault(user, 101), false);
        userYieldVaults = c.getYieldVaultIdsForUser(user);
        assertEq(userYieldVaults.length, 3);

        // Verify remaining yieldvaults
        assertEq(c.doesUserOwnYieldVault(user, 42), true);
        assertEq(c.doesUserOwnYieldVault(user, 100), true);
        assertEq(c.doesUserOwnYieldVault(user, 102), true);
    }

    function test_YieldVaultIndex_CloseAllYieldVaults() public {
        // Close the existing yieldvault from setUp
        vm.prank(user);
        uint256 closeReq = c.closeYieldVault(42);

        vm.startPrank(coa);
        _startProcessingBatch(closeReq);
        c.completeProcessing(closeReq, true, 42, "Closed");
        vm.stopPrank();

        uint64[] memory userYieldVaults = c.getYieldVaultIdsForUser(user);
        assertEq(userYieldVaults.length, 0, "User should have no yieldvaults");
        assertEq(c.doesUserOwnYieldVault(user, 42), false);
    }

    // ============================================
    // STRESS TESTS FOR GAS OPTIMIZATION
    // ============================================

    function test_ManyRequests_MaintainsCorrectState() public {
        uint256 numRequests = 20;
        uint256[] memory requestIds = new uint256[](numRequests);

        // Increase max pending requests limit
        vm.prank(c.owner());
        c.setMaxPendingRequestsPerUser(25);

        // Create many requests
        vm.startPrank(user);
        for (uint256 i = 0; i < numRequests; i++) {
            requestIds[i] = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        }
        vm.stopPrank();

        assertEq(c.getPendingRequestCount(), numRequests);

        vm.startPrank(coa);
        for (uint256 i = 0; i < numRequests / 2; i++) {
            _startProcessingBatch(requestIds[i]);
            c.completeProcessing(requestIds[i], true, uint64(100 + i), "Created");
        }
        vm.stopPrank();

        // Should have 10 remaining
        assertEq(c.getPendingRequestCount(), numRequests / 2);

        // Verify FIFO order is maintained for remaining requests
        (uint256[] memory ids, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(ids.length, numRequests / 2);

        // Pending requests should remain in order
        for (uint256 i = 0; i < ids.length - 1; i++) {
            assertEq(ids[i], requestIds[numRequests/2 + i], "FIFO order not maintained");
        }
    }

    function test_ManyUsers_IndependentTracking() public {
        address[] memory users = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            users[i] = makeAddr(string(abi.encodePacked("testUser", i)));
            vm.deal(users[i], 100 ether);
        }

        // Each user creates 3 requests
        uint256[][] memory userRequestIds = new uint256[][](5);
        for (uint256 i = 0; i < 5; i++) {
            userRequestIds[i] = new uint256[](3);
            vm.startPrank(users[i]);
            for (uint256 j = 0; j < 3; j++) {
                userRequestIds[i][j] = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
            }
            vm.stopPrank();
        }

        // Process user[1]'s first request
        vm.startPrank(coa);
        _startProcessingBatch(userRequestIds[0][0]);
        c.completeProcessing(userRequestIds[0][0], true, 300, "Created");
        vm.stopPrank();

        // Verify all other users still have 3 requests
        for (uint256 i = 0; i < 5; i++) {
            (uint256[] memory ids, , , , , , , , , , , ) = c.getPendingRequestsByUserUnpacked(users[i]);
            if (i == 0) {
                assertEq(ids.length, 2, "User 1 should have 2 requests");
            } else {
                assertEq(ids.length, 3, "Other users should have 3 requests");
            }
        }
    }

    // ============================================
    // EDGE CASES
    // ============================================

    function test_SingleRequest_RemoveCorrectly() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.startPrank(coa);
        _startProcessingBatch(reqId);
        c.completeProcessing(reqId, true, 100, "Created");
        vm.stopPrank();

        assertEq(c.getPendingRequestCount(), 0);

        (uint256[] memory ids, , , , , , , , , , , ) = c.getPendingRequestsByUserUnpacked(user);
        assertEq(ids.length, 0);
    }

    function test_FailedProcessing_RestoresUserArray() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        // Start and fail processing req1
        vm.startPrank(coa);
        _startProcessingBatch(req1);
        // COA must return funds when completing with failure
        c.completeProcessing{value: 1 ether}(req1, false, c.NO_YIELDVAULT_ID(), "Failed");
        vm.stopPrank();

        // req1 should still be removed from pending (it's marked FAILED)
        (uint256[] memory ids, , , , , , , , , , uint256 pendingBalance, uint256 claimableRefund) = c.getPendingRequestsByUserUnpacked(user);
        assertEq(ids.length, 1, "Should have 1 pending request");
        assertEq(ids[0], req2);
        // Escrowed balance only includes req2
        assertEq(pendingBalance, 2 ether, "Escrowed balance should be req2 amount");
        // Refunded amount is in claimableRefunds
        assertEq(claimableRefund, 1 ether, "Claimable refund should be req1 amount");
    }

    function test_CancelMiddleRequest_UpdatesIndexCorrectly() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);
        uint256 req3 = c.createYieldVault{value: 3 ether}(NATIVE_FLOW, 3 ether, VAULT_ID, STRATEGY_ID);

        // Cancel middle request
        c.cancelRequest(req2);
        vm.stopPrank();

        // Verify global FIFO order
        (uint256[] memory globalIds, , , , , , , , , , ) = c.getPendingRequestsUnpacked(0, 0);
        assertEq(globalIds.length, 2);
        assertEq(globalIds[0], req1, "First should be req1");
        assertEq(globalIds[1], req3, "Second should be req3");

        // Verify user's array
        (uint256[] memory userIds, , , , , , , , , , , ) = c.getPendingRequestsByUserUnpacked(user);
        assertEq(userIds.length, 2);
    }

    // Test that duplicate registration is blocked
    function test_RegisterYieldVault_RevertAlreadyRegistered() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.startPrank(coa);
        _startProcessingBatch(reqId);
        c.completeProcessing(reqId, true, 100, "Created");

        // Try to register same ID again (simulate COA bug)
        uint256 reqId2 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        _startProcessingBatch(reqId2);
        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.YieldVaultIdAlreadyRegistered.selector,
            100
        ));
        c.completeProcessing(reqId2, true, 100, "Duplicate");
        vm.stopPrank();
    }

    // Test that ID mismatch on DEPOSIT is blocked
    function test_CompleteProcessing_RevertDepositIdMismatch() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.startPrank(coa);
        _startProcessingBatch(reqId);
        c.completeProcessing(reqId, true, 100, "Created");
        vm.stopPrank();

        // Try to deposit but COA provides wrong ID
        vm.prank(user);
        uint256 depositReq = c.depositToYieldVault{value: 1 ether}(100, NATIVE_FLOW, 1 ether);

        vm.startPrank(coa);
        _startProcessingBatch(depositReq);
        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.YieldVaultIdMismatch.selector,
            100,  // expected
            101   // provided (wrong)
        ));
        c.completeProcessing(depositReq, true, 101, "Wrong ID");
        vm.stopPrank();
    }

    // Test for unregister with wrong user ownership
    function test_CompleteProcessing_RevertInvalidYieldVaultId() public {
        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.startPrank(coa);
        _startProcessingBatch(reqId);
        c.completeProcessing(reqId, true, 100, "Created");
        vm.stopPrank();

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.InvalidYieldVaultId.selector,
            100,
            user2
        ));
        uint256 closeReq = c.closeYieldVault(100);
    }

    function test_CreateYieldVault_MsgValueValidation() public {
        vm.startPrank(user);

        vm.expectRevert(FlowYieldVaultsRequests.MsgValueMustEqualAmount.selector);
        c.createYieldVault{value: 5 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);

        vm.expectRevert(FlowYieldVaultsRequests.MsgValueMustBeZero.selector);
        c.createYieldVault{value: 5 ether}(WFLOW, 5 ether, VAULT_ID, STRATEGY_ID);

        vm.stopPrank();
    }

    function test_CreateYieldVault_RevertTokenNotSupported() public {
        deal(address(dai), user2, 20 ether);
        assertEq(dai.balanceOf(user2), 20 ether);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.TokenNotSupported.selector,
            address(dai)
        ));
        c.createYieldVault(address(dai), 5 ether, VAULT_ID, STRATEGY_ID);
    }

    function test_DepositToYieldVault_MsgValueValidation() public {
        vm.prank(user);
        vm.expectRevert(FlowYieldVaultsRequests.MsgValueMustEqualAmount.selector);
        c.depositToYieldVault{value: 5 ether}(42, NATIVE_FLOW, 1 ether);

        c.testRegisterYieldVaultId(101, user, WFLOW);
        vm.prank(user);
        vm.expectRevert(FlowYieldVaultsRequests.MsgValueMustBeZero.selector);
        c.depositToYieldVault{value: 5 ether}(101, WFLOW, 5 ether);
    }

    function test_DepositToYieldVault_RevertTokenNotSupported() public {
        deal(address(dai), user2, 20 ether);
        assertEq(dai.balanceOf(user2), 20 ether);

        c.testRegisterYieldVaultId(101, user2, address(dai));

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.TokenNotSupported.selector,
            address(dai)
        ));
        c.depositToYieldVault{value: 5 ether}(101, address(dai), 1 ether);
    }

    function test_CompleteProcessing_MsgValueValidation() public {
        vm.prank(user);
        uint256 req1 = c.createYieldVault{value: 5 ether}(NATIVE_FLOW, 5 ether, VAULT_ID, STRATEGY_ID);

        vm.prank(coa);
        _startProcessingBatch(req1);

        uint64 sentinelYieldVaultId = c.NO_YIELDVAULT_ID();
        vm.prank(coa);
        vm.expectRevert(FlowYieldVaultsRequests.MsgValueMustEqualAmount.selector);
        c.completeProcessing{value: 3 ether}(req1, false, sentinelYieldVaultId, "Failed");

        c.testRegisterYieldVaultId(101, user2, address(dai));
        c.setTokenConfig(address(dai), true, 0.5 ether, false);

        vm.startPrank(user2);
        deal(address(dai), user2, 20 ether);
        dai.approve(address(c), 5 ether);
        uint256 req2 = c.depositToYieldVault(101, address(dai), 5 ether);
        vm.stopPrank();

        vm.prank(coa);
        _startProcessingBatch(req2);

        vm.prank(coa);
        vm.expectRevert(FlowYieldVaultsRequests.MsgValueMustBeZero.selector);
        c.completeProcessing{value: 5 ether}(req2, false, 101, "Failed");

        // Success case must also reject non-zero msg.value (the `else` branch)
        vm.prank(coa);
        vm.expectRevert(FlowYieldVaultsRequests.MsgValueMustBeZero.selector);
        c.completeProcessing{value: 1 ether}(req2, true, 101, "Success");
    }

    function test_CompleteProcessing_RefundNativeFunds() public {
        assertEq(user.balance, 100 ether);
        assertEq(address(c).balance, 0 ether);

        vm.prank(user);
        uint256 reqId = c.createYieldVault{value: 5 ether}(NATIVE_FLOW, 5 ether, VAULT_ID, STRATEGY_ID);
        assertEq(user.balance, 95 ether);
        assertEq(address(c).balance, 5 ether);

        vm.prank(coa);
        _startProcessingBatch(reqId);
        assertEq(coa.balance, 5 ether);
        assertEq(address(c).balance, 0 ether);

        uint64 sentinelYieldVaultId = c.NO_YIELDVAULT_ID();
        vm.prank(coa);
        c.completeProcessing{value: 5 ether}(reqId, false, sentinelYieldVaultId, "Failed");
        assertEq(coa.balance, 0 ether);
        assertEq(address(c).balance, 5 ether);

        vm.prank(user);
        c.claimRefund(NATIVE_FLOW);
        assertEq(coa.balance, 0 ether);
        assertEq(address(c).balance, 0 ether);
        assertEq(user.balance, 100 ether);
    }

    function test_CompleteProcessing_RefundERC20Tokens() public {
        vm.prank(c.owner());
        c.testRegisterYieldVaultId(101, user, address(dai));
        c.setTokenConfig(address(dai), true, 0.5 ether, false);

        deal(address(dai), user, 20 ether);
        assertEq(dai.balanceOf(user), 20 ether);
        assertEq(dai.balanceOf(address(c)), 0 ether);

        vm.startPrank(user);
        dai.approve(address(c), 5 ether);
        uint256 reqId = c.createYieldVault(address(dai), 5 ether, VAULT_ID, STRATEGY_ID);
        assertEq(dai.balanceOf(user), 15 ether);
        assertEq(dai.balanceOf(address(c)), 5 ether);
        vm.stopPrank();

        vm.prank(coa);
        _startProcessingBatch(reqId);
        assertEq(dai.balanceOf(coa), 5 ether);
        assertEq(dai.balanceOf(address(c)), 0 ether);

        vm.startPrank(coa);
        dai.approve(address(c), 5 ether);
        c.completeProcessing(reqId, false, c.NO_YIELDVAULT_ID(), "Failed");
        assertEq(dai.balanceOf(coa), 0 ether);
        assertEq(dai.balanceOf(address(c)), 5 ether);
        vm.stopPrank();

        vm.prank(user);
        c.claimRefund(address(dai));
        assertEq(dai.balanceOf(coa), 0 ether);
        assertEq(dai.balanceOf(address(c)), 0 ether);
        assertEq(dai.balanceOf(user), 20 ether);
    }

    function test_RecoverTokens() public {
        deal(address(dai), user2, 20 ether);
        assertEq(dai.balanceOf(user2), 20 ether);

        vm.startPrank(user2);
        dai.transfer(address(c), 5 ether);
        assertEq(dai.balanceOf(user2), 15 ether);
        assertEq(dai.balanceOf(address(c)), 5 ether);
        vm.stopPrank();

        vm.startPrank(c.owner());
        vm.expectEmit(true, true, true, true);
        emit TokensRecovered(user2, address(dai), 5 ether);
        c.recoverTokens(user2, address(dai), 5 ether);
        assertEq(dai.balanceOf(user2), 20 ether);
        assertEq(dai.balanceOf(address(c)), 0 ether);
        vm.stopPrank();
    }

    function test_RecoverTokens_RevertInsufficientRecoveryAmount() public {
        deal(address(dai), user2, 20 ether);
        assertEq(dai.balanceOf(user2), 20 ether);

        vm.startPrank(user2);
        dai.transfer(address(c), 5 ether);
        assertEq(dai.balanceOf(user2), 15 ether);
        assertEq(dai.balanceOf(address(c)), 5 ether);
        vm.stopPrank();

        vm.prank(c.owner());
        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.InsufficientRecoveryAmount.selector,
            5 ether,
            25 ether
        ));
        c.recoverTokens(user2, address(dai), 25 ether);
    }

    function test_RecoverTokens_RevertInvalidRecoveryUserAddress() public {
        vm.prank(c.owner());
        vm.expectRevert(FlowYieldVaultsRequests.InvalidRecoveryUserAddress.selector);
        c.recoverTokens(address(0), address(dai), 25 ether);
    }

    function test_RecoverTokens_RevertInvalidRecoveryTokenAddress() public {
        vm.prank(c.owner());
        vm.expectRevert(FlowYieldVaultsRequests.InvalidRecoveryTokenAddress.selector);
        c.recoverTokens(user2, NATIVE_FLOW, 25 ether);
    }

    function test_RecoverTokens_WithPendingUserBalanceAndNoExcessAmount() public {
        vm.prank(c.owner());
        c.testRegisterYieldVaultId(101, user, address(dai));
        c.setTokenConfig(address(dai), true, 0.5 ether, false);

        deal(address(dai), user, 20 ether);
        assertEq(dai.balanceOf(user), 20 ether);
        assertEq(dai.balanceOf(address(c)), 0 ether);

        vm.startPrank(user);
        dai.approve(address(c), 5 ether);
        uint256 reqId = c.createYieldVault(address(dai), 5 ether, VAULT_ID, STRATEGY_ID);
        assertEq(dai.balanceOf(user), 15 ether);
        assertEq(dai.balanceOf(address(c)), 5 ether);
        vm.stopPrank();

        vm.prank(c.owner());
        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.InsufficientRecoveryAmount.selector,
            0 ether,
            5 ether
        ));
        c.recoverTokens(user, address(dai), 5 ether);
    }

    function test_RecoverTokens_WithCancelledRequestAndNoExcessAmount() public {
        vm.prank(c.owner());
        c.testRegisterYieldVaultId(101, user, address(dai));
        c.setTokenConfig(address(dai), true, 0.5 ether, false);

        deal(address(dai), user, 20 ether);
        assertEq(dai.balanceOf(user), 20 ether);
        assertEq(dai.balanceOf(address(c)), 0 ether);

        vm.startPrank(user);
        dai.approve(address(c), 5 ether);
        uint256 reqId = c.createYieldVault(address(dai), 5 ether, VAULT_ID, STRATEGY_ID);
        assertEq(dai.balanceOf(user), 15 ether);
        assertEq(dai.balanceOf(address(c)), 5 ether);

        c.cancelRequest(reqId);
        vm.stopPrank();

        vm.prank(c.owner());
        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.InsufficientRecoveryAmount.selector,
            0 ether,
            5 ether
        ));
        c.recoverTokens(user, address(dai), 5 ether);
    }

    function test_RecoverTokens_WithClaimableRefundAndNoExcessAmount() public {
        vm.prank(c.owner());
        c.testRegisterYieldVaultId(101, user, address(dai));
        c.setTokenConfig(address(dai), true, 0.5 ether, false);

        deal(address(dai), user, 20 ether);
        assertEq(dai.balanceOf(user), 20 ether);
        assertEq(dai.balanceOf(address(c)), 0 ether);

        vm.startPrank(user);
        dai.approve(address(c), 5 ether);
        uint256 reqId = c.createYieldVault(address(dai), 5 ether, VAULT_ID, STRATEGY_ID);
        assertEq(dai.balanceOf(user), 15 ether);
        assertEq(dai.balanceOf(address(c)), 5 ether);
        vm.stopPrank();

        vm.prank(coa);
        _startProcessingBatch(reqId);
        assertEq(dai.balanceOf(coa), 5 ether);
        assertEq(dai.balanceOf(address(c)), 0 ether);

        vm.startPrank(coa);
        dai.approve(address(c), 5 ether);
        c.completeProcessing(reqId, false, c.NO_YIELDVAULT_ID(), "Failed");
        assertEq(dai.balanceOf(coa), 0 ether);
        assertEq(dai.balanceOf(address(c)), 5 ether);
        vm.stopPrank();

        vm.prank(c.owner());
        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.InsufficientRecoveryAmount.selector,
            0 ether,
            5 ether
        ));
        c.recoverTokens(user, address(dai), 5 ether);
    }

    function test_RecoverTokens_WithProcessingRequestAndExcessAmount() public {
        vm.prank(c.owner());
        c.testRegisterYieldVaultId(101, user, address(dai));
        c.setTokenConfig(address(dai), true, 0.5 ether, false);

        deal(address(dai), user, 20 ether);
        assertEq(dai.balanceOf(user), 20 ether);
        assertEq(dai.balanceOf(address(c)), 0 ether);

        vm.startPrank(user);
        dai.approve(address(c), 5 ether);
        uint256 reqId = c.createYieldVault(address(dai), 5 ether, VAULT_ID, STRATEGY_ID);
        assertEq(dai.balanceOf(user), 15 ether);
        assertEq(dai.balanceOf(address(c)), 5 ether);
        vm.stopPrank();

        vm.prank(coa);
        _startProcessingBatch(reqId);
        assertEq(dai.balanceOf(coa), 5 ether);
        assertEq(dai.balanceOf(address(c)), 0 ether);

        vm.prank(user);
        dai.transfer(address(c), 3 ether);

        vm.prank(c.owner());
        c.recoverTokens(user, address(dai), 3 ether);
        assertEq(dai.balanceOf(address(c)), 0 ether);
        assertEq(dai.balanceOf(user), 15 ether);
    }

    function test_RecoverTokens_RevertWhenAccountedExceedsAmount() public {
        c.testRegisterYieldVaultId(101, user, address(dai));
        c.setTokenConfig(address(dai), true, 0.5 ether, false);
        deal(address(dai), user, 20 ether);
        vm.startPrank(user);
        dai.approve(address(c), 5 ether);
        c.createYieldVault(address(dai), 5 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        // contract has a balance of 5 DAI via the above createYieldVault,
        // but there is no excess balance for the given token.
        vm.prank(c.owner());
        vm.expectRevert(abi.encodeWithSelector(
            FlowYieldVaultsRequests.InsufficientRecoveryAmount.selector,
            0,
            3 ether
        ));
        c.recoverTokens(user, address(dai), 3 ether);
    }

    function test_RecoverTokens_WithAccountedLessThanAmount() public {
        c.testRegisterYieldVaultId(101, user, address(dai));
        c.setTokenConfig(address(dai), true, 0.5 ether, false);
        deal(address(dai), user, 20 ether);
        vm.startPrank(user);
        dai.approve(address(c), 5 ether);
        c.createYieldVault(address(dai), 5 ether, VAULT_ID, STRATEGY_ID);
        vm.stopPrank();

        vm.prank(user);
        dai.transfer(address(c), 8 ether);
        assertEq(dai.balanceOf(address(c)), 13 ether);

        // contract has 5 ether in pendingUserBalances via createYieldVault
        vm.prank(c.owner());
        c.recoverTokens(user, address(dai), 8 ether);
        // user still has 5 ether in pendingUserBalances via createYieldVault,
        // even after the stray token recovery
        assertEq(c.getUserPendingBalance(user, address(dai)), 5 ether);
        assertEq(dai.balanceOf(address(c)), 5 ether);
    }

    function test_RecoverTokens_RevertWhenNotOwner() public {
        deal(address(dai), user2, 5 ether);
        vm.prank(user2);
        dai.transfer(address(c), 5 ether);

        vm.prank(user2); // non-owner
        vm.expectRevert(abi.encodeWithSelector(
            OwnableUnauthorizedAccount.selector,
            user2
        ));
        c.recoverTokens(user2, address(dai), 5 ether);
    }

    function test_RecoverTokens_RevertInvalidRecoveryUserAddress_ContractSelf() public {
        vm.prank(c.owner());
        vm.expectRevert(FlowYieldVaultsRequests.InvalidRecoveryUserAddress.selector);
        c.recoverTokens(address(c), address(dai), 1 ether);
    }

    function test_RecoverTokens_RevertAmountIsZero() public {
        vm.prank(c.owner());
        vm.expectRevert(FlowYieldVaultsRequests.AmountMustBeGreaterThanZero.selector);
        c.recoverTokens(user2, address(dai), 0);
    }

    function test_CancelRequests_RandomOrder() public {
        vm.startPrank(user);
        uint256 req1 = c.createYieldVault{value: 1 ether}(NATIVE_FLOW, 1 ether, VAULT_ID, STRATEGY_ID);
        uint256 req2 = c.createYieldVault{value: 2 ether}(NATIVE_FLOW, 2 ether, VAULT_ID, STRATEGY_ID);
        uint256 req3 = c.createYieldVault{value: 3 ether}(NATIVE_FLOW, 3 ether, VAULT_ID, STRATEGY_ID);
        uint256 req4 = c.createYieldVault{value: 4 ether}(NATIVE_FLOW, 4 ether, VAULT_ID, STRATEGY_ID);
        uint256 req5 = c.createYieldVault{value: 5 ether}(NATIVE_FLOW, 5 ether, VAULT_ID, STRATEGY_ID);

        uint256[] memory requestIDs = c.getPendingRequestIds();

        assertEq(requestIDs.length, 5);
        assertEq(requestIDs[0], req1, "First should be req1");
        assertEq(requestIDs[1], req2, "Second should be req2");
        assertEq(requestIDs[2], req3, "Third should be req3");
        assertEq(requestIDs[3], req4, "Fourth should be req4");
        assertEq(requestIDs[4], req5, "Fifth should be req5");

        // Cancel last request
        c.cancelRequest(req5);
        requestIDs = c.getPendingRequestIds();

        assertEq(requestIDs.length, 4);
        assertEq(requestIDs[0], req1, "First should be req1");
        assertEq(requestIDs[1], req2, "Second should be req2");
        assertEq(requestIDs[2], req3, "Third should be req3");
        assertEq(requestIDs[3], req4, "Fourth should be req4");

        // Cancel first request
        c.cancelRequest(req1);
        requestIDs = c.getPendingRequestIds();

        assertEq(requestIDs.length, 3);
        assertEq(requestIDs[0], req2, "First should be req2");
        assertEq(requestIDs[1], req3, "Second should be req3");
        assertEq(requestIDs[2], req4, "Third should be req4");

        // Cancel middle request
        c.cancelRequest(req3);
        requestIDs = c.getPendingRequestIds();

        assertEq(requestIDs.length, 2);
        assertEq(requestIDs[0], req2, "First should be req2");
        assertEq(requestIDs[1], req4, "Second should be req4");
        vm.stopPrank();

        vm.prank(c.owner());
        c.dropRequests(requestIDs);

        assertEq(c.getPendingRequestIds().length, 0);
    }
}
