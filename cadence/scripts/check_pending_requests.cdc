import "FlowVaultsEVM"

/// @title Check Pending Requests
/// @notice Returns the count of pending requests from FlowVaultsRequests
/// @param contractAddr The address where FlowVaultsEVM Worker is stored
/// @return Number of pending requests
///
access(all) fun main(contractAddr: Address): Int {
    let account = getAuthAccount<auth(Storage) &Account>(contractAddr)

    let worker = account.storage.borrow<&FlowVaultsEVM.Worker>(
        from: FlowVaultsEVM.WorkerStoragePath
    ) ?? panic("No Worker found")

    let requests = worker.getPendingRequestsFromEVM()

    return requests.length
}
