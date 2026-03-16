import "FlowYieldVaultsEVM"

/// @title Check Pending Requests
/// @notice Returns the count of pending requests fetched for the requested page
/// @param contractAddr The address where FlowYieldVaultsEVM Worker is stored
/// @param startIndex The index to start fetching requests from
/// @param count The number of requests to fetch
/// @return Number of pending requests fetched in this page
///
access(all) fun main(contractAddr: Address, startIndex: Int, count: Int): Int {
    let account = getAuthAccount<auth(Storage) &Account>(contractAddr)

    let worker = account.storage.borrow<&FlowYieldVaultsEVM.Worker>(
        from: FlowYieldVaultsEVM.WorkerStoragePath
    ) ?? panic("No Worker found")

    if let requests = worker.getPendingRequestsFromEVM(startIndex: startIndex, count: count) {
        return requests.length
    }
    panic("Failed to fetch pending requests from EVM")
}
