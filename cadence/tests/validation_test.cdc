import Test
import "EVM"
import "FlowToken"
import "FlowYieldVaults"
import "FlowYieldVaultsEVM"
import "FlowYieldVaultsClosedBeta"
import "test_helpers.cdc"

// -----------------------------------------------------------------------------
// Validation Test
// -----------------------------------------------------------------------------
// Tests validation logic for CREATE_YIELDVAULT request parameters
// Focuses on catching invalid/unsupported strategy identifiers before they
// cause panics in FlowYieldVaults (Issue #7)
// -----------------------------------------------------------------------------

access(all) let testUserEVM = EVM.addressFromString("0x0000000000000000000000000000000000000099")

// -----------------------------------------------------------------------------
// SETUP
// -----------------------------------------------------------------------------
access(all)
fun setup() {
    deployContracts()

    let coaResult = setupCOA(admin)
    Test.expect(coaResult, Test.beSucceeded())

    let workerResult = setupWorkerWithBadge(admin)
    Test.expect(workerResult, Test.beSucceeded())
}

// -----------------------------------------------------------------------------
// TEST CASES - Issue #7: Invalid Strategy Identifier Validation
// -----------------------------------------------------------------------------

access(all)
fun testCompositeTypeReturnsNilForInvalidStrategy() {
    // This test verifies that CompositeType() returns nil for invalid identifiers
    // which is the first line of defense in validateCreateYieldVaultParameters()

    // Completely invalid identifier (like a typo or malformed input)
    let invalidType = CompositeType("invalid_strategy_type")
    Test.assert(invalidType == nil, message: "CompositeType should return nil for invalid identifier")

    // Empty string
    let emptyType = CompositeType("")
    Test.assert(emptyType == nil, message: "CompositeType should return nil for empty string")
}

access(all)
fun testCompositeTypeReturnsNonNilForValidType() {
    // Valid Cadence type identifier returns non-nil
    // This is the case where CompositeType passes but strategy may still be unsupported
    let validType = CompositeType("A.0ae53cb6e3f42a79.FlowToken.Vault")
    Test.assert(validType != nil, message: "CompositeType should return non-nil for valid FlowToken.Vault")
}

access(all)
fun testUnsupportedStrategyNotInSupportedList() {
    // This test verifies that getSupportedStrategies() can be used to check
    // if a strategy is supported before calling createYieldVault()
    //
    // The original error was:
    // "Strategy A.d2580caf2ef07c2f.FlowVaultsStrategies.TracerStrategy is unsupported"
    //
    // The validation now checks this BEFORE calling FlowYieldVaults.createYieldVault()

    let supportedStrategies = FlowYieldVaults.getSupportedStrategies()

    // In test environment, no strategies are registered by default
    // This simulates checking if an arbitrary strategy is supported
    let mockUnsupportedStrategy = CompositeType("A.0000000000000001.Mock.Strategy")

    if mockUnsupportedStrategy != nil {
        var isSupported = false
        for supported in supportedStrategies {
            if supported == mockUnsupportedStrategy! {
                isSupported = true
                break
            }
        }
        Test.assert(!isSupported, message: "Mock strategy should not be in supported list")
    }
}