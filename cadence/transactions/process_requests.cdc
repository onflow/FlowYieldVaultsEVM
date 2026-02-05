import "FlowYieldVaultsEVM"

/// @title Process Requests Manually (preprocess and process) (PENDING -> COMPLETED/FAILED)
/// @notice Manually processes pending requests from FlowYieldVaultsRequests contract
/// @dev Fetches and processes up to count pending requests starting from startIndex.
///      Use for manual processing or debugging. Automated processing uses the transaction handler.
///      Performs both preprocess and processing steps.
/// @param startIndex The index to start fetching requests from
/// @param count The number of requests to fetch and process
///
transaction(startIndex: Int, count: Int) {
    prepare(signer: auth(BorrowValue) &Account) {
        let worker = signer.storage.borrow<&FlowYieldVaultsEVM.Worker>(
            from: FlowYieldVaultsEVM.WorkerStoragePath
        ) ?? panic("Could not borrow Worker from storage")

        let requests = worker.getPendingRequestsFromEVM(
            startIndex: startIndex,
            count: count,
        )

        // Preprocess requests
        if let successfulRequests = worker.preprocessRequests(requests) {

            // Process requests
            worker.processRequests(successfulRequests)

        } else {
            panic("Failed to preprocess requests")
        }

    }
}
