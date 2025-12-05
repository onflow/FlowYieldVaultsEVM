import "FlowYieldVaultsEVM"

/// @title Process Requests
/// @notice Manually processes pending requests from FlowYieldVaultsRequests contract
/// @dev Fetches and processes up to count pending requests starting from startIndex.
///      Use for manual processing or debugging. Automated processing uses the transaction handler.
/// @param startIndex The index to start fetching requests from
/// @param count The number of requests to fetch and process
///
transaction(startIndex: Int, count: Int) {
    prepare(signer: auth(BorrowValue) &Account) {
        let worker = signer.storage.borrow<&FlowYieldVaultsEVM.Worker>(
            from: FlowYieldVaultsEVM.WorkerStoragePath
        ) ?? panic("Could not borrow Worker from storage")

        worker.processRequests(startIndex: startIndex, count: count)
    }
}
