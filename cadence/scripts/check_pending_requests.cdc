import "TidalEVM"

access(all) fun main(contractAddr: Address): Int {
    let account = getAuthAccount<auth(Storage) &Account>(contractAddr)
    
    let worker = account.storage.borrow<&TidalEVM.Worker>(
        from: TidalEVM.WorkerStoragePath
    ) ?? panic("No Worker found")
    
    let requests = worker.getPendingRequestsFromEVM()
    
    log("Found ".concat(requests.length.toString()).concat(" pending requests"))
    
    for request in requests {
        log("Request ID: ".concat(request.id.toString()))
        log("  Type: ".concat(request.requestType.toString()))
        log("  User: ".concat(request.user.toString()))
        log("  Amount: ".concat(request.amount.toString()))
        log("  Status: ".concat(request.status.toString()))
    }
    
    return requests.length
}