import Test
import "EVM"
import "FlowToken"
import "FlowYieldVaults"
import "FlowYieldVaultsEVM"
import "FlowYieldVaultsClosedBeta"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Error Handling & Edge Cases Test
// -----------------------------------------------------------------------------
// Tests error scenarios and boundary conditions for EVM integration
// -----------------------------------------------------------------------------

access(all) let testUserEVM = EVM.addressFromString("0x0000000000000000000000000000000000000099")

// -----------------------------------------------------------------------------
// SETUP
// -----------------------------------------------------------------------------
access(all)
fun setup() {
    deployContracts()

    // Setup worker
    let coaResult = setupCOA(admin)
    Test.expect(coaResult, Test.beSucceeded())

    let workerResult = setupWorkerWithBadge(admin)
    Test.expect(workerResult, Test.beSucceeded())
}

// -----------------------------------------------------------------------------
// TEST CASES
// -----------------------------------------------------------------------------

access(all)
fun testInvalidRequestType() {
    // --- arrange & act -----------------------------------------------------
    // Attempting to create request with invalid type (99) should fail at precondition
    // This validates that the EVMRequest struct enforces valid request types

    // Test each valid request type
    let validTypes: [UInt8] = [
        FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue,
        FlowYieldVaultsEVM.RequestType.DEPOSIT_TO_YIELDVAULT.rawValue,
        FlowYieldVaultsEVM.RequestType.WITHDRAW_FROM_YIELDVAULT.rawValue,
        FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue
    ]

    for requestType in validTypes {
        var amount = 1000000000000000000 as UInt256
        if requestType == FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue {
            amount = 0
        }

        let validRequest = FlowYieldVaultsEVM.EVMRequest(
            id: UInt256(requestType),
            user: testUserEVM,
            requestType: requestType,
            status: FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue,
            tokenAddress: nativeFlowAddr,
            amount: amount,
            yieldVaultId: UInt64.max,
            timestamp: 0,
            message: "",
            vaultIdentifier: mockVaultIdentifier,
            strategyIdentifier: mockStrategyIdentifier
        )

        Test.assertEqual(requestType, validRequest.requestType)
    }

    // --- assert ------------------------------------------------------------
    // Verify boundary values (0 and 3 are valid, values outside should fail)
    Test.assertEqual(0 as UInt8, FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue)
    Test.assertEqual(3 as UInt8, FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue)

    Test.expectFailure(fun(): Void {
        let closeWithPositiveAmount = FlowYieldVaultsEVM.EVMRequest(
            id: 3,
            user: testUserEVM,
            requestType: 99,
            status: FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue,
            tokenAddress: nativeFlowAddr,
            amount: 1100,
            yieldVaultId: 1,
            timestamp: 0,
            message: "",
            vaultIdentifier: "",
            strategyIdentifier: ""
        )
    }, errorMessageSubstring: "Invalid request type: expected 0 (CREATE_YIELDVAULT) to 3 (CLOSE_YIELDVAULT) but got 99")
}

access(all)
fun testZeroAmountWithdrawal() {
    // --- arrange & act -----------------------------------------------------
    // Test that zero amount is allowed for CLOSE_YIELDVAULT operations
    let closeWithZeroAmount = FlowYieldVaultsEVM.EVMRequest(
        id: 3,
        user: testUserEVM,
        requestType: FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue,
        status: FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 0, // Zero amount allowed for CLOSE_YIELDVAULT
        yieldVaultId: 1,
        timestamp: 0,
        message: "",
        vaultIdentifier: "",
        strategyIdentifier: ""
    )

    // --- assert ------------------------------------------------------------
    Test.assertEqual(0 as UInt256, closeWithZeroAmount.amount)
    Test.assertEqual(FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue, closeWithZeroAmount.requestType)

    Test.expectFailure(fun(): Void {
        let closeWithPositiveAmount = FlowYieldVaultsEVM.EVMRequest(
            id: 3,
            user: testUserEVM,
            requestType: FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue,
            status: FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue,
            tokenAddress: nativeFlowAddr,
            amount: 1100, // Positive amount not allowed for CLOSE_YIELDVAULT
            yieldVaultId: 1,
            timestamp: 0,
            message: "",
            vaultIdentifier: "",
            strategyIdentifier: ""
        )
    }, errorMessageSubstring: "Amount must be equal to 0 for requestType 3 but got amount 1100")

    let requestTypes: [UInt8] = [
        FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue,
        FlowYieldVaultsEVM.RequestType.DEPOSIT_TO_YIELDVAULT.rawValue,
        FlowYieldVaultsEVM.RequestType.WITHDRAW_FROM_YIELDVAULT.rawValue
    ]

    for requestType in requestTypes {
        Test.expectFailure(fun(): Void {
            let closeWithPositiveAmount = FlowYieldVaultsEVM.EVMRequest(
                id: 3,
                user: testUserEVM,
                requestType: requestType,
                status: FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue,
                tokenAddress: nativeFlowAddr,
                amount: 0, // Zero amount not allowed for create/deposit/withdraw requests
                yieldVaultId: 1,
                timestamp: 0,
                message: "",
                vaultIdentifier: "",
                strategyIdentifier: ""
            )
        }, errorMessageSubstring: "Amount must be greater than 0 for requestType \(requestType) but got amount 0")
    }

    // Note: Zero amounts for CREATE_YIELDVAULT, DEPOSIT_TO_YIELDVAULT, and WITHDRAW_FROM_YIELDVAULT
    // would fail at struct initialization with error:
    // "Amount must be greater than 0 for CREATE_YIELDVAULT, DEPOSIT_TO_YIELDVAULT, and WITHDRAW_FROM_YIELDVAULT operations"
}

access(all)
fun testRequestStatusCompletedStructure() {
    // Test creating requests with COMPLETED status
    let completedRequest = FlowYieldVaultsEVM.EVMRequest(
        id: 7,
        user: testUserEVM,
        requestType: FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue,
        status: FlowYieldVaultsEVM.RequestStatus.COMPLETED.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 1000000000000000000,
        yieldVaultId: 1,
        timestamp: 0,
        message: "Successfully created",
        vaultIdentifier: mockVaultIdentifier,
        strategyIdentifier: mockStrategyIdentifier
    )

    Test.assertEqual(FlowYieldVaultsEVM.RequestStatus.COMPLETED.rawValue, completedRequest.status)
    Test.assertEqual("Successfully created", completedRequest.message)
}

access(all)
fun testRequestStatusFailedStructure() {
    // Test creating requests with FAILED status
    let failedRequest = FlowYieldVaultsEVM.EVMRequest(
        id: 8,
        user: testUserEVM,
        requestType: FlowYieldVaultsEVM.RequestType.DEPOSIT_TO_YIELDVAULT.rawValue,
        status: FlowYieldVaultsEVM.RequestStatus.FAILED.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 1000000000000000000,
        yieldVaultId: 1,
        timestamp: 0,
        message: "Insufficient balance",
        vaultIdentifier: "",
        strategyIdentifier: ""
    )

    Test.assertEqual(FlowYieldVaultsEVM.RequestStatus.FAILED.rawValue, failedRequest.status)
    Test.assertEqual("Insufficient balance", failedRequest.message)
}

access(all)
fun testMarkRequestAsFailedRejectsFalseApproveRefunds() {
    let requestsResult = updateRequestsAddress(admin, mockRequestsAddr.toString())
    Test.expect(requestsResult, Test.beSucceeded())

    let requestFailedCountBefore = Test.eventsOfType(Type<FlowYieldVaultsEVM.RequestFailed>()).length
    let falseApproveTokenAddress = deployFalseApproveToken(admin)

    let markFailedResult = _executeTransaction(
        "transactions/mark_request_as_failed_false_approve.cdc",
        [falseApproveTokenAddress],
        admin
    )
    Test.expect(markFailedResult, Test.beSucceeded())

    let requestFailedEvents = Test.eventsOfType(Type<FlowYieldVaultsEVM.RequestFailed>())
    Test.assert(
        requestFailedEvents.length > requestFailedCountBefore,
        message: "Expected RequestFailed events for the approve(false) refund path"
    )

    let lastEvent = requestFailedEvents[requestFailedEvents.length - 1] as! FlowYieldVaultsEVM.RequestFailed
    let expectedTokenAddress = EVM.addressFromString(falseApproveTokenAddress).toString()
    Test.assertEqual(4242 as UInt256, lastEvent.requestId)
    Test.assertEqual(expectedTokenAddress, lastEvent.tokenAddress)
    Test.assertEqual(
        "ERC20 approve for refund returned false or invalid bool data",
        lastEvent.reason
    )
}
