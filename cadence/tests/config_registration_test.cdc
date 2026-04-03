import Test
import "FlowYieldVaultsEVM"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Config Registration Test
// -----------------------------------------------------------------------------
// Tests cross-VM admin registration flows for CREATE_YIELDVAULT configs.
// -----------------------------------------------------------------------------

access(all)
fun setup() {
    deployContracts()

    let coaResult = setupCOA(admin)
    Test.expect(coaResult, Test.beSucceeded())

    let workerResult = setupWorkerWithBadge(admin)
    Test.expect(workerResult, Test.beSucceeded())

    let setAddrResult = updateRequestsAddress(admin, mockRequestsAddr.toString())
    Test.expect(setAddrResult, Test.beSucceeded())
}

access(all)
fun testRegisterCreateYieldVaultConfigEverywhere_RollsBackOnEVMFailure() {
    Test.assert(
        FlowYieldVaultsEVM.getCreateYieldVaultConfig(mockCreateVaultConfigId) == nil,
        message: "Config should not exist before registration"
    )

    let registerResult = registerCreateYieldVaultConfigEverywhere(
        admin,
        mockCreateVaultConfigId,
        mockVaultIdentifier,
        mockStrategyIdentifier
    )
    Test.assertEqual(Test.ResultStatus.failed, registerResult.status)

    Test.assert(
        FlowYieldVaultsEVM.getCreateYieldVaultConfig(mockCreateVaultConfigId) == nil,
        message: "Cadence config should roll back if the EVM registration fails"
    )
}

access(all)
fun testDirectCadenceOnlyConfigRegistrationIsForbidden() {
    let registerResult = registerCreateYieldVaultConfigDirectAdminForTest(
        admin,
        mockCreateVaultConfigId,
        mockVaultIdentifier,
        mockStrategyIdentifier
    )
    Test.assertEqual(Test.ResultStatus.failed, registerResult.status)

    Test.assert(
        FlowYieldVaultsEVM.getCreateYieldVaultConfig(mockCreateVaultConfigId) == nil,
        message: "Cadence config should remain unset when direct Admin registration is attempted"
    )
}

access(all)
fun testDirectEVMOnlyConfigRegistrationIsForbidden() {
    let registerResult = registerCreateYieldVaultConfigDirectWorkerForTest(
        admin,
        mockCreateVaultConfigId,
        mockVaultIdentifier,
        mockStrategyIdentifier
    )
    Test.assertEqual(Test.ResultStatus.failed, registerResult.status)

    Test.assert(
        FlowYieldVaultsEVM.getCreateYieldVaultConfig(mockCreateVaultConfigId) == nil,
        message: "Cadence config should remain unset when direct Worker registration is attempted"
    )
}
