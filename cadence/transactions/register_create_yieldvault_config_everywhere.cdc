import "FlowYieldVaultsEVM"

/// @title Register Create YieldVault Config Everywhere
/// @notice Registers an immutable CREATE_YIELDVAULT config on both Cadence and the EVM request contract
/// @dev Borrows both Admin and Worker from the same signer account and delegates to the contract's only
///      public config-registration entrypoint. If the EVM call fails, the entire transaction reverts and
///      the local Cadence registration is rolled back.
///
/// @param configId Immutable config ID shared with the EVM request contract
/// @param vaultIdentifier Cadence vault type identifier
/// @param strategyIdentifier Cadence strategy type identifier
transaction(configId: UInt64, vaultIdentifier: String, strategyIdentifier: String) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowYieldVaultsEVM.Admin>(
            from: FlowYieldVaultsEVM.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        let worker = signer.storage.borrow<&FlowYieldVaultsEVM.Worker>(
            from: FlowYieldVaultsEVM.WorkerStoragePath
        ) ?? panic("Could not borrow Worker resource")

        FlowYieldVaultsEVM.registerCreateYieldVaultConfigEverywhere(
            admin: admin,
            worker: worker,
            configId: configId,
            vaultIdentifier: vaultIdentifier,
            strategyIdentifier: strategyIdentifier
        )
    }
}
