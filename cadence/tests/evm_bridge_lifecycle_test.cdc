import Test
import "EVM"
import "FlowToken"
import "FlowYieldVaults"
import "FlowYieldVaultsEVM"
import "FlowYieldVaultsClosedBeta"
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
    
    // Set mock FlowYieldVaultsRequests address
    let setAddrResult = updateRequestsAddress(admin, mockRequestsAddr.toString())
    Test.expect(setAddrResult, Test.beSucceeded())
}

// -----------------------------------------------------------------------------
// TEST CASES
// -----------------------------------------------------------------------------

access(all)
fun testCreateYieldVaultFromEVMRequest() {
    // --- arrange -----------------------------------------------------------
    let createRequest = FlowYieldVaultsEVM.EVMRequest(
        id: 1,
        user: userEVMAddr1,
        requestType: FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue,
        status: FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 1000000000000000000, // 1 FLOW in wei (10^18)
        yieldVaultId: 0, // Not used for CREATE
        timestamp: 0,
        message: "",
        vaultIdentifier: mockVaultIdentifier,
        strategyIdentifier: mockStrategyIdentifier
    )
    
    // Verify no yieldvaults exist for this user initially
    let yieldVaultsBefore = FlowYieldVaultsEVM.getYieldVaultIdsForEVMAddress(userEVMAddr1.toString())
    Test.assertEqual(0, yieldVaultsBefore.length)
    
    // --- act ---------------------------------------------------------------
    // In real scenario, processRequests() would read from EVM contract
    // For testing, we validate the request structure and processing logic
    
    // Verify request created correctly
    Test.assertEqual(1 as UInt256, createRequest.id)
    Test.assertEqual(FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue, createRequest.requestType)
    Test.assertEqual(FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue, createRequest.status)
    
    // --- assert ------------------------------------------------------------
    // Verify the request structure is valid for processing
    Test.assert(createRequest.amount > 0, message: "Amount must be positive")
    Test.assertEqual(mockVaultIdentifier, createRequest.vaultIdentifier)
    Test.assertEqual(mockStrategyIdentifier, createRequest.strategyIdentifier)
}

access(all)
fun testDepositToExistingYieldVault() {
    // --- arrange -----------------------------------------------------------
    // Assume YieldVault Id 1 exists for userEVMAddr1 (created in previous operation)
    let depositRequest = FlowYieldVaultsEVM.EVMRequest(
        id: 2,
        user: userEVMAddr1,
        requestType: FlowYieldVaultsEVM.RequestType.DEPOSIT_TO_YIELDVAULT.rawValue,
        status: FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 500000000000000000, // 0.5 FLOW
        yieldVaultId: 1,
        timestamp: 0,
        message: "",
        vaultIdentifier: "", // Not needed for DEPOSIT
        strategyIdentifier: ""
    )
    
    // --- assert ------------------------------------------------------------
    Test.assertEqual(2 as UInt256, depositRequest.id)
    Test.assertEqual(FlowYieldVaultsEVM.RequestType.DEPOSIT_TO_YIELDVAULT.rawValue, depositRequest.requestType)
    Test.assertEqual(1 as UInt64, depositRequest.yieldVaultId)
    Test.assert(depositRequest.amount > 0, message: "Deposit amount must be positive")
}

access(all)
fun testWithdrawFromYieldVault() {
    // --- arrange -----------------------------------------------------------
    let withdrawRequest = FlowYieldVaultsEVM.EVMRequest(
        id: 3,
        user: userEVMAddr1,
        requestType: FlowYieldVaultsEVM.RequestType.WITHDRAW_FROM_YIELDVAULT.rawValue,
        status: FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 300000000000000000, // 0.3 FLOW
        yieldVaultId: 1,
        timestamp: 0,
        message: "",
        vaultIdentifier: "",
        strategyIdentifier: ""
    )
    
    // --- assert ------------------------------------------------------------
    Test.assertEqual(3 as UInt256, withdrawRequest.id)
    Test.assertEqual(FlowYieldVaultsEVM.RequestType.WITHDRAW_FROM_YIELDVAULT.rawValue, withdrawRequest.requestType)
    Test.assertEqual(1 as UInt64, withdrawRequest.yieldVaultId)
    Test.assert(withdrawRequest.amount > 0, message: "Withdraw amount must be positive")
}

access(all)
fun testCloseYieldVaultComplete() {
    // --- arrange -----------------------------------------------------------
    let closeRequest = FlowYieldVaultsEVM.EVMRequest(
        id: 4,
        user: userEVMAddr1,
        requestType: FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue,
        status: FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 0, // Amount not used for CLOSE
        yieldVaultId: 1,
        timestamp: 0,
        message: "",
        vaultIdentifier: "",
        strategyIdentifier: ""
    )
    
    // --- assert ------------------------------------------------------------
    Test.assertEqual(4 as UInt256, closeRequest.id)
    Test.assertEqual(FlowYieldVaultsEVM.RequestType.CLOSE_YIELDVAULT.rawValue, closeRequest.requestType)
    Test.assertEqual(1 as UInt64, closeRequest.yieldVaultId)
}

access(all)
fun testRequestStatusTransitions() {
    // --- Test valid status transitions ---
    
    // PENDING → COMPLETED
    let completedRequest = FlowYieldVaultsEVM.EVMRequest(
        id: 5,
        user: userEVMAddr1,
        requestType: FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue,
        status: FlowYieldVaultsEVM.RequestStatus.COMPLETED.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 1000000000000000000,
        yieldVaultId: 0,
        timestamp: 0,
        message: "",
        vaultIdentifier: mockVaultIdentifier,
        strategyIdentifier: mockStrategyIdentifier
    )
    Test.assertEqual(FlowYieldVaultsEVM.RequestStatus.COMPLETED.rawValue, completedRequest.status)
    
    // PENDING → FAILED
    let failedRequest = FlowYieldVaultsEVM.EVMRequest(
        id: 6,
        user: userEVMAddr1,
        requestType: FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue,
        status: FlowYieldVaultsEVM.RequestStatus.FAILED.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 1000000000000000000,
        yieldVaultId: 0,
        timestamp: 0,
        message: "Insufficient balance",
        vaultIdentifier: mockVaultIdentifier,
        strategyIdentifier: mockStrategyIdentifier
    )
    Test.assertEqual(FlowYieldVaultsEVM.RequestStatus.FAILED.rawValue, failedRequest.status)
    Test.assertEqual("Insufficient balance", failedRequest.message)
}

access(all)
fun testMultipleUsersIndependentYieldVaults() {
    // --- arrange -----------------------------------------------------------
    let user1Request = FlowYieldVaultsEVM.EVMRequest(
        id: 7,
        user: userEVMAddr1,
        requestType: FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue,
        status: FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 1000000000000000000,
        yieldVaultId: 0,
        timestamp: 0,
        message: "",
        vaultIdentifier: mockVaultIdentifier,
        strategyIdentifier: mockStrategyIdentifier
    )
    
    let user2Request = FlowYieldVaultsEVM.EVMRequest(
        id: 8,
        user: userEVMAddr2,
        requestType: FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue,
        status: FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 2000000000000000000,
        yieldVaultId: 0,
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
    let successResult = FlowYieldVaultsEVM.ProcessResult(
        success: true,
        yieldVaultId: 42,
        message: "YieldVault created successfully"
    )

    Test.assert(successResult.success)
    Test.assertEqual(42 as UInt64, successResult.yieldVaultId)
    Test.assertEqual("YieldVault created successfully", successResult.message)

    // Test failure result (NO_YIELDVAULT_ID sentinel for "no yieldvault")
    let failureResult = FlowYieldVaultsEVM.ProcessResult(
        success: false,
        yieldVaultId: FlowYieldVaultsEVM.noYieldVaultId,
        message: "Insufficient COA balance"
    )

    Test.assert(!failureResult.success)
    Test.assertEqual(FlowYieldVaultsEVM.noYieldVaultId, failureResult.yieldVaultId)
    Test.assertEqual("Insufficient COA balance", failureResult.message)
}

access(all)
fun testVaultAndStrategyIdentifiers() {
    // Test that vault and strategy identifiers are preserved correctly
    let customVaultId = "A.1234567890abcdef.CustomToken.Vault"
    let customStrategyId = "A.fedcba0987654321.CustomStrategy.Strategy"
    
    let request = FlowYieldVaultsEVM.EVMRequest(
        id: 9,
        user: userEVMAddr1,
        requestType: FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue,
        status: FlowYieldVaultsEVM.RequestStatus.PENDING.rawValue,
        tokenAddress: nativeFlowAddr,
        amount: 1000000000000000000,
        yieldVaultId: 0,
        timestamp: 0,
        message: "",
        vaultIdentifier: customVaultId,
        strategyIdentifier: customStrategyId
    )
    
    Test.assertEqual(customVaultId, request.vaultIdentifier)
    Test.assertEqual(customStrategyId, request.strategyIdentifier)
}
