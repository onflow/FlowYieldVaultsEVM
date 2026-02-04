import "FlowYieldVaultsEVM"

/// @title Process Requests Manually
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

        // Preprocess requests and separate into successful and rejected
        let successfulRequestIds: [UInt256] = []
        let rejectedRequestIds: [UInt256] = []
        let successfulRequests: [FlowYieldVaultsEVM.EVMRequest] = []
        for request in requests {
            let result = worker.preprocessRequest(request)
            if !result.success {
                log("Rejected request: \(request.id)")
                rejectedRequestIds.append(request.id)
            } else {
                let newRequest = FlowYieldVaultsEVM.EVMRequest(
                    id: request.id,
                    user: request.user,
                    requestType: request.requestType,
                    // Update status to PROCESSING
                    status: FlowYieldVaultsEVM.RequestStatus.PROCESSING.rawValue,
                    tokenAddress: request.tokenAddress,
                    amount: request.amount,
                    yieldVaultId: request.yieldVaultId,
                    timestamp: request.timestamp,
                    message: request.message,
                    vaultIdentifier: request.vaultIdentifier,
                    strategyIdentifier: request.strategyIdentifier,
                )
                successfulRequests.append(newRequest)
                successfulRequestIds.append(request.id)
            }
        }

        // PENDING -> PROCESSING / FAILED
        if let errorMessage = worker.startProcessingBatch(
            successfulRequestIds: successfulRequestIds,
            rejectedRequestIds: rejectedRequestIds,
        ) {
            log("Error starting processing batch: \(errorMessage)")
        }

        // PROCESSING -> COMPLETED/FAILED
        worker.processRequests(successfulRequests)

    }
}
