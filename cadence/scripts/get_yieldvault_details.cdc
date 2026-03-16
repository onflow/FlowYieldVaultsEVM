import "FlowYieldVaults"

/// @title Get YieldVault Details
/// @notice Returns the public details of a specific YieldVault
/// @param managerAddress The account address that stores the YieldVaultManager
/// @param yieldVaultId The ID of the YieldVault to query
/// @return Dictionary with the YieldVault's public metadata
///
access(all) fun main(managerAddress: Address, yieldVaultId: UInt64): {String: AnyStruct} {
    let managerRef = getAccount(managerAddress)
        .capabilities.borrow<&FlowYieldVaults.YieldVaultManager>(FlowYieldVaults.YieldVaultManagerPublicPath)
        ?? panic("Could not borrow YieldVaultManager")

    let yieldVaultRef = managerRef.borrowYieldVault(id: yieldVaultId)
        ?? panic("YieldVault not found")

    return {
        "id": yieldVaultRef.id(),
        "balance": yieldVaultRef.getYieldVaultBalance(),
        "vaultType": yieldVaultRef.getVaultTypeIdentifier(),
        "strategyType": yieldVaultRef.getStrategyType()
    }
}
