import "FlowYieldVaults"

/// Validates CREATE_YIELDVAULT request parameters before submission
/// Returns a struct with validation results for both vaultIdentifier and strategyIdentifier
///
/// @param vaultIdentifier The Cadence vault type identifier (e.g., "A.0ae53cb6e3f42a79.FlowToken.Vault")
/// @param strategyIdentifier The Cadence strategy type identifier (e.g., "A.xxx.FlowYieldVaultsStrategies.TracerStrategy")
/// @return ValidationResult containing isValid flag and detailed error messages if invalid
access(all) struct ValidationResult {
    access(all) let isValid: Bool
    access(all) let vaultIdentifierValid: Bool
    access(all) let strategyIdentifierValid: Bool
    access(all) let strategySupported: Bool
    access(all) let vaultSupportedForStrategy: Bool
    access(all) let errorMessage: String
    access(all) let supportedStrategies: [String]

    init(
        isValid: Bool,
        vaultIdentifierValid: Bool,
        strategyIdentifierValid: Bool,
        strategySupported: Bool,
        vaultSupportedForStrategy: Bool,
        errorMessage: String,
        supportedStrategies: [String]
    ) {
        self.isValid = isValid
        self.vaultIdentifierValid = vaultIdentifierValid
        self.strategyIdentifierValid = strategyIdentifierValid
        self.strategySupported = strategySupported
        self.vaultSupportedForStrategy = vaultSupportedForStrategy
        self.errorMessage = errorMessage
        self.supportedStrategies = supportedStrategies
    }
}

access(all) fun main(vaultIdentifier: String, strategyIdentifier: String): ValidationResult {
    var errorMessages: [String] = []

    // Get supported strategies for reference
    let supportedStrategyTypes = FlowYieldVaults.getSupportedStrategies()
    var supportedStrategies: [String] = []
    for strategyType in supportedStrategyTypes {
        supportedStrategies.append(strategyType.identifier)
    }

    // Validate vaultIdentifier is a valid Cadence type
    let vaultType = CompositeType(vaultIdentifier)
    let vaultIdentifierValid = vaultType != nil
    if !vaultIdentifierValid {
        errorMessages.append("Invalid vaultIdentifier: '\(vaultIdentifier)' is not a valid Cadence type")
    }

    // Validate strategyIdentifier is a valid Cadence type
    let strategyType = CompositeType(strategyIdentifier)
    let strategyIdentifierValid = strategyType != nil
    if !strategyIdentifierValid {
        errorMessages.append("Invalid strategyIdentifier: '\(strategyIdentifier)' is not a valid Cadence type")
    }

    // Check if strategy is supported by FlowYieldVaults
    var strategySupported = false
    if strategyType != nil {
        for supported in supportedStrategyTypes {
            if supported == strategyType! {
                strategySupported = true
                break
            }
        }
        if !strategySupported {
            var strategiesList = "none"
            if supportedStrategies.length > 0 {
                strategiesList = supportedStrategies[0]
                var idx = 1
                while idx < supportedStrategies.length {
                    strategiesList = "\(strategiesList), \(supportedStrategies[idx])"
                    idx = idx + 1
                }
            }
            errorMessages.append("Unsupported strategy: '\(strategyIdentifier)' is not supported by FlowYieldVaults. Supported strategies: \(strategiesList)")
        }
    }

    // Check if vault type is supported for this strategy
    var vaultSupportedForStrategy = false
    if strategySupported && vaultType != nil {
        let supportedVaults = FlowYieldVaults.getSupportedInitializationVaults(forStrategy: strategyType!)
        vaultSupportedForStrategy = supportedVaults[vaultType!] == true
        if !vaultSupportedForStrategy {
            var supportedVaultIds: [String] = []
            for vaultTypeKey in supportedVaults.keys {
                supportedVaultIds.append(vaultTypeKey.identifier)
            }
            var vaultsList = "none"
            if supportedVaultIds.length > 0 {
                vaultsList = supportedVaultIds[0]
                var idx = 1
                while idx < supportedVaultIds.length {
                    vaultsList = "\(vaultsList), \(supportedVaultIds[idx])"
                    idx = idx + 1
                }
            }
            errorMessages.append("Unsupported vault type: '\(vaultIdentifier)' cannot be used to initialize strategy '\(strategyIdentifier)'. Supported vaults: \(vaultsList)")
        }
    }

    let isValid = vaultIdentifierValid && strategyIdentifierValid && strategySupported && vaultSupportedForStrategy
    let errorMessage = errorMessages.length > 0 ? errorMessages[0] : ""

    return ValidationResult(
        isValid: isValid,
        vaultIdentifierValid: vaultIdentifierValid,
        strategyIdentifierValid: strategyIdentifierValid,
        strategySupported: strategySupported,
        vaultSupportedForStrategy: vaultSupportedForStrategy,
        errorMessage: errorMessage,
        supportedStrategies: supportedStrategies
    )
}
