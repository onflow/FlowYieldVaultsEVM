import "FlowVaultsEVM"

access(all) fun main(contractAddr: Address): Int {
    let account = getAuthAccount<auth(Storage) &Account>(contractAddr)
    
    let worker = account.storage.borrow<&FlowVaultsEVM.Worker>(
        from: FlowVaultsEVM.WorkerStoragePath
    ) ?? panic("No Worker found")
    
    let requests = worker.getPendingRequestsFromEVM()
    
    return requests.length
}