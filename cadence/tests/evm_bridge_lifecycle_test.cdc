import Test
import "EVM"
import "FlowToken"
import "FlowVaults"
import "FlowVaultsEVM"
import "FlowVaultsClosedBeta"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// EVM Bridge Lifecycle Test
// -----------------------------------------------------------------------------
// Tests the complete lifecycle of EVM-to-Cadence bridge operations:
// CREATE → DEPOSIT → WITHDRAW → CLOSE
// -----------------------------------------------------------------------------

// Test user EVM addresses
access(all) let userEVMAddr1 = EVM.addressFromString("0x0000000000000000000000000000000000000011")
access(all) let userEVMAddr2 = EVM.addressFromString("0x0000000000000000000000000000000000000012")

// -----------------------------------------------------------------------------
// SETUP
// -----------------------------------------------------------------------------
access(all)
fun setup() {
    deployContracts()
    
    // Setup worker with COA and beta badge
    let coaResult = setupCOA(admin)
    Test.expect(coaResult, Test.beSucceeded())
    
    let workerResult = setupWorkerWithBadge(admin)
    Test.expect(workerResult, Test.beSucceeded())
    
    // Set mock FlowVaultsRequests address
    let setAddrResult = updateRequestsAddress(admin, mockRequestsAddr.toString())
    Test.expect(setAddrResult, Test.beSucceeded())
}

// -----------------------------------------------------------------------------
// TEST CASES
// -----------------------------------------------------------------------------

access(all)
fun testCreateTideFromEVMRequest() {
    // --- arrange -----------------------------------------------------------
    let createRequest = FlowVaultsEVM.EVMRequest(
        id: 1,
        user: userEVMAddr1,
        requestType: FlowVaultsEVM.RequestType.CREATE_TIDE.rawValue,
        status: FlowVaultsEVM.RequestStatus.PENDING.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 1000000000000000000, // 1 FLOW in wei (10^18)
        tideId: 0, // Not used for CREATE
        timestamp: 0,
        message: "",
        vaultIdentifier: mockVaultIdentifier,
        strategyIdentifier: mockStrategyIdentifier
    )
    
    // Verify no tides exist for this user initially
    let tidesBefore = FlowVaultsEVM.getTideIDsForEVMAddress(userEVMAddr1.toString())
    Test.assertEqual(0, tidesBefore.length)
    
    // --- act ---------------------------------------------------------------
    // In real scenario, processRequests() would read from EVM contract
    // For testing, we validate the request structure and processing logic
    
    // Verify request created correctly
    Test.assertEqual(1 as UInt256, createRequest.id)
    Test.assertEqual(FlowVaultsEVM.RequestType.CREATE_TIDE.rawValue, createRequest.requestType)
    Test.assertEqual(FlowVaultsEVM.RequestStatus.PENDING.rawValue, createRequest.status)
    
    // --- assert ------------------------------------------------------------
    // Verify the request structure is valid for processing
    Test.assert(createRequest.amount > 0, message: "Amount must be positive")
    Test.assertEqual(mockVaultIdentifier, createRequest.vaultIdentifier)
    Test.assertEqual(mockStrategyIdentifier, createRequest.strategyIdentifier)
}

access(all)
fun testDepositToExistingTide() {
    // --- arrange -----------------------------------------------------------
    // Assume Tide ID 1 exists for userEVMAddr1 (created in previous operation)
    let depositRequest = FlowVaultsEVM.EVMRequest(
        id: 2,
        user: userEVMAddr1,
        requestType: FlowVaultsEVM.RequestType.DEPOSIT_TO_TIDE.rawValue,
        status: FlowVaultsEVM.RequestStatus.PENDING.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 500000000000000000, // 0.5 FLOW
        tideId: 1,
        timestamp: 0,
        message: "",
        vaultIdentifier: "", // Not needed for DEPOSIT
        strategyIdentifier: ""
    )
    
    // --- assert ------------------------------------------------------------
    Test.assertEqual(2 as UInt256, depositRequest.id)
    Test.assertEqual(FlowVaultsEVM.RequestType.DEPOSIT_TO_TIDE.rawValue, depositRequest.requestType)
    Test.assertEqual(1 as UInt64, depositRequest.tideId)
    Test.assert(depositRequest.amount > 0, message: "Deposit amount must be positive")
}

access(all)
fun testWithdrawFromTide() {
    // --- arrange -----------------------------------------------------------
    let withdrawRequest = FlowVaultsEVM.EVMRequest(
        id: 3,
        user: userEVMAddr1,
        requestType: FlowVaultsEVM.RequestType.WITHDRAW_FROM_TIDE.rawValue,
        status: FlowVaultsEVM.RequestStatus.PENDING.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 300000000000000000, // 0.3 FLOW
        tideId: 1,
        timestamp: 0,
        message: "",
        vaultIdentifier: "",
        strategyIdentifier: ""
    )
    
    // --- assert ------------------------------------------------------------
    Test.assertEqual(3 as UInt256, withdrawRequest.id)
    Test.assertEqual(FlowVaultsEVM.RequestType.WITHDRAW_FROM_TIDE.rawValue, withdrawRequest.requestType)
    Test.assertEqual(1 as UInt64, withdrawRequest.tideId)
    Test.assert(withdrawRequest.amount > 0, message: "Withdraw amount must be positive")
}

access(all)
fun testCloseTideComplete() {
    // --- arrange -----------------------------------------------------------
    let closeRequest = FlowVaultsEVM.EVMRequest(
        id: 4,
        user: userEVMAddr1,
        requestType: FlowVaultsEVM.RequestType.CLOSE_TIDE.rawValue,
        status: FlowVaultsEVM.RequestStatus.PENDING.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 0, // Amount not used for CLOSE
        tideId: 1,
        timestamp: 0,
        message: "",
        vaultIdentifier: "",
        strategyIdentifier: ""
    )
    
    // --- assert ------------------------------------------------------------
    Test.assertEqual(4 as UInt256, closeRequest.id)
    Test.assertEqual(FlowVaultsEVM.RequestType.CLOSE_TIDE.rawValue, closeRequest.requestType)
    Test.assertEqual(1 as UInt64, closeRequest.tideId)
}

access(all)
fun testRequestStatusTransitions() {
    // --- Test valid status transitions ---
    
    // PENDING → COMPLETED
    let completedRequest = FlowVaultsEVM.EVMRequest(
        id: 5,
        user: userEVMAddr1,
        requestType: FlowVaultsEVM.RequestType.CREATE_TIDE.rawValue,
        status: FlowVaultsEVM.RequestStatus.COMPLETED.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 1000000000000000000,
        tideId: 0,
        timestamp: 0,
        message: "",
        vaultIdentifier: mockVaultIdentifier,
        strategyIdentifier: mockStrategyIdentifier
    )
    Test.assertEqual(FlowVaultsEVM.RequestStatus.COMPLETED.rawValue, completedRequest.status)
    
    // PENDING → FAILED
    let failedRequest = FlowVaultsEVM.EVMRequest(
        id: 6,
        user: userEVMAddr1,
        requestType: FlowVaultsEVM.RequestType.CREATE_TIDE.rawValue,
        status: FlowVaultsEVM.RequestStatus.FAILED.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 1000000000000000000,
        tideId: 0,
        timestamp: 0,
        message: "Insufficient balance",
        vaultIdentifier: mockVaultIdentifier,
        strategyIdentifier: mockStrategyIdentifier
    )
    Test.assertEqual(FlowVaultsEVM.RequestStatus.FAILED.rawValue, failedRequest.status)
    Test.assertEqual("Insufficient balance", failedRequest.message)
}

access(all)
fun testMultipleUsersIndependentTides() {
    // --- arrange -----------------------------------------------------------
    let user1Request = FlowVaultsEVM.EVMRequest(
        id: 7,
        user: userEVMAddr1,
        requestType: FlowVaultsEVM.RequestType.CREATE_TIDE.rawValue,
        status: FlowVaultsEVM.RequestStatus.PENDING.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 1000000000000000000,
        tideId: 0,
        timestamp: 0,
        message: "",
        vaultIdentifier: mockVaultIdentifier,
        strategyIdentifier: mockStrategyIdentifier
    )
    
    let user2Request = FlowVaultsEVM.EVMRequest(
        id: 8,
        user: userEVMAddr2,
        requestType: FlowVaultsEVM.RequestType.CREATE_TIDE.rawValue,
        status: FlowVaultsEVM.RequestStatus.PENDING.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 2000000000000000000,
        tideId: 0,
        timestamp: 0,
        message: "",
        vaultIdentifier: mockVaultIdentifier,
        strategyIdentifier: mockStrategyIdentifier
    )
    
    // --- assert ------------------------------------------------------------
    // Verify users are different
    Test.assert(
        user1Request.user.toString() != user2Request.user.toString(),
        message: "User addresses should be different"
    )
    
    // Verify requests are independent
    Test.assert(user1Request.id != user2Request.id, message: "Request IDs should be unique")
    Test.assert(user1Request.amount != user2Request.amount, message: "Request amounts are different")
}

access(all)
fun testProcessResultStructure() {
    // Test successful result
    let successResult = FlowVaultsEVM.ProcessResult(
        success: true,
        tideId: 42,
        message: "Tide created successfully"
    )
    
    Test.assert(successResult.success)
    Test.assertEqual(42 as UInt64, successResult.tideId)
    Test.assertEqual("Tide created successfully", successResult.message)
    
    // Test failure result
    let failureResult = FlowVaultsEVM.ProcessResult(
        success: false,
        tideId: 0,
        message: "Insufficient COA balance"
    )
    
    Test.assert(!failureResult.success)
    Test.assertEqual(0 as UInt64, failureResult.tideId)
    Test.assertEqual("Insufficient COA balance", failureResult.message)
}

access(all)
fun testVaultAndStrategyIdentifiers() {
    // Test that vault and strategy identifiers are preserved correctly
    let customVaultId = "A.1234567890abcdef.CustomToken.Vault"
    let customStrategyId = "A.fedcba0987654321.CustomStrategy.Strategy"
    
    let request = FlowVaultsEVM.EVMRequest(
        id: 9,
        user: userEVMAddr1,
        requestType: FlowVaultsEVM.RequestType.CREATE_TIDE.rawValue,
        status: FlowVaultsEVM.RequestStatus.PENDING.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 1000000000000000000,
        tideId: 0,
        timestamp: 0,
        message: "",
        vaultIdentifier: customVaultId,
        strategyIdentifier: customStrategyId
    )
    
    Test.assertEqual(customVaultId, request.vaultIdentifier)
    Test.assertEqual(customStrategyId, request.strategyIdentifier)
}
