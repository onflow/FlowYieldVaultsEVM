import "FlowYieldVaultsEVM"

transaction(configId: UInt64, vaultIdentifier: String, strategyIdentifier: String) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowYieldVaultsEVM.Admin>(
            from: FlowYieldVaultsEVM.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        admin.registerCreateYieldVaultConfig(
            configId: configId,
            vaultIdentifier: vaultIdentifier,
            strategyIdentifier: strategyIdentifier
        )
    }
}
