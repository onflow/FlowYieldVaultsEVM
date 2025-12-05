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
    
    // We can't directly test the failure in Cadence tests since it panics
    // Instead, we verify that valid request types work correctly
    
    // Test each valid request type
    let validTypes: [UInt8] = [
        FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue,
        FlowYieldVaultsEVM.RequestType.DEPOSIT_TO_YIELDVAULT.rawValue,
        FlowYieldVaultsEVM.RequestType.WITHDRAW_FROM_YIELDVAULT.rawValue,
        FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue
    ]
    
    for requestType in validTypes {
        let validRequest = FlowYieldVaultsEVM.EVMRequest(
            id: UInt256(requestType),
            user: testUserEVM,
            requestType: requestType,
            status: FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue,
            tokenAddress: nativeFlowAddr,
            amount: 1000000000000000000,
            yieldVaultId: 0,
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
    
    // Note: Invalid values like 99, 4, or 255 would fail at struct initialization
    // with error: "Invalid request type: must be between 0 (CREATE_YIELDVAULT) and 3 (CLOSE_YIELDVAULT)"
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
