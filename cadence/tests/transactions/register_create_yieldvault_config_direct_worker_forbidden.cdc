import "FlowYieldVaultsEVM"

transaction(configId: UInt64, vaultIdentifier: String, strategyIdentifier: String) {
    prepare(signer: auth(BorrowValue) &Account) {
        let worker = signer.storage.borrow<&FlowYieldVaultsEVM.Worker>(
            from: FlowYieldVaultsEVM.WorkerStoragePath
        ) ?? panic("Could not borrow Worker resource")

        worker.registerCreateYieldVaultConfigOnEVM(
            configId: configId,
            vaultIdentifier: vaultIdentifier,
            strategyIdentifier: strategyIdentifier
        )
    }
}
