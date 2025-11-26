import "FlowVaultsEVM"

/// @title Process Requests
/// @notice Manually processes pending requests from FlowVaultsRequests contract
/// @dev Fetches and processes up to maxRequestsPerTx pending requests.
///      Use for manual processing or debugging. Automated processing uses the transaction handler.
///
transaction() {
    prepare(signer: auth(BorrowValue) &Account) {
        let worker = signer.storage.borrow<&FlowVaultsEVM.Worker>(
            from: FlowVaultsEVM.WorkerStoragePath
        ) ?? panic("Could not borrow Worker from storage")

        worker.processRequests()
    }
}
