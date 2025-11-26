import "FlowVaultsEVM"

/// @title Check Pending Requests
/// @notice Returns the count of pending requests from FlowVaultsRequests
/// @param contractAddr The address where FlowVaultsEVM Worker is stored
/// @param startIndex The index to start fetching requests from
/// @param count The number of requests to fetch
/// @return Number of pending requests
///
access(all) fun main(contractAddr: Address, startIndex: Int, count: Int): Int {
    let account = getAuthAccount<auth(Storage) &Account>(contractAddr)

    let worker = account.storage.borrow<&FlowVaultsEVM.Worker>(
        from: FlowVaultsEVM.WorkerStoragePath
    ) ?? panic("No Worker found")

    let requests = worker.getPendingRequestsFromEVM(startIndex: startIndex, count: count)

    return requests.length
}
