import "FlowYieldVaultsEVM"

/// @title Drop Requests
/// @notice Drops pending requests on the EVM contract and refunds users
/// @dev Requires Worker resource. The Worker's COA must be the owner of the Solidity contract.
///      This is an admin cleanup function that marks requests as FAILED and returns escrowed funds.
///
/// @param requestIds Array of request IDs to drop
///
transaction(requestIds: [UInt256]) {
    prepare(signer: auth(BorrowValue) &Account) {
        let worker = signer.storage.borrow<&FlowYieldVaultsEVM.Worker>(
            from: FlowYieldVaultsEVM.WorkerStoragePath
        ) ?? panic("Could not borrow FlowYieldVaultsEVM Worker resource")

        worker.dropRequests(requestIds)
    }
}
