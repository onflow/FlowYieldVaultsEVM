import "FlowYieldVaultsEVM"

/// @title Set Blocklist Enabled
/// @notice Enables or disables the blocklist on the EVM FlowYieldVaultsRequests contract
/// @dev Requires Worker resource. The Worker's COA must be the owner of the Solidity contract.
///
/// @param enabled True to enable blocklist enforcement, false to disable
///
transaction(enabled: Bool) {
    prepare(signer: auth(BorrowValue) &Account) {
        let worker = signer.storage.borrow<&FlowYieldVaultsEVM.Worker>(
            from: FlowYieldVaultsEVM.WorkerStoragePath
        ) ?? panic("Could not borrow FlowYieldVaultsEVM Worker resource")

        worker.setBlocklistEnabled(enabled)
    }
}
