import "FlowYieldVaults"

/// @title Get YieldVault Balance
/// @notice Returns the balance of a specific YieldVault
/// @param managerAddress The address where the YieldVaultManager is stored
/// @param yieldVaultId The ID of the YieldVault to query
/// @return The balance of the YieldVault in FLOW (UFix64), or 0.0 if not found
///
access(all) fun main(managerAddress: Address, yieldVaultId: UInt64): UFix64 {
    let managerRef = getAccount(managerAddress)
        .capabilities.borrow<&FlowYieldVaults.YieldVaultManager>(FlowYieldVaults.YieldVaultManagerPublicPath)

    if managerRef == nil {
        return 0.0
    }

    let yieldVaultRef = managerRef!.borrowYieldVault(id: yieldVaultId)
    if yieldVaultRef == nil {
        return 0.0
    }

    return yieldVaultRef!.getYieldVaultBalance()
}
