import "FlowYieldVaultsEVM"
import "EVM"

/// @title Batch Add to Allowlist
/// @notice Adds multiple addresses to the allowlist on the EVM FlowYieldVaultsRequests contract
/// @dev Requires Worker resource. The Worker's COA must be the owner of the Solidity contract.
///      Empty arrays will cause the transaction to fail on the Solidity side.
///
/// @param addresses Array of EVM address strings to add to the allowlist
///
transaction(addresses: [String]) {
    prepare(signer: auth(BorrowValue) &Account) {
        let worker = signer.storage.borrow<&FlowYieldVaultsEVM.Worker>(
            from: FlowYieldVaultsEVM.WorkerStoragePath
        ) ?? panic("Could not borrow FlowYieldVaultsEVM Worker resource")

        var evmAddresses: [EVM.EVMAddress] = []
        for addr in addresses {
            evmAddresses.append(EVM.addressFromString(addr))
        }

        worker.batchAddToAllowlist(evmAddresses)
    }
}
