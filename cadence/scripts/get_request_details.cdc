import "FlowVaultsEVM"

access(all) fun main(contractAddr: Address): {String: AnyStruct} {
    let account = getAuthAccount<auth(Storage) &Account>(contractAddr)
    
    let worker = account.storage.borrow<&FlowVaultsEVM.Worker>(
        from: FlowVaultsEVM.WorkerStoragePath
    ) ?? panic("No Worker found")
    
    let requests = worker.getPendingRequestsFromEVM()
    
    if requests.length == 0 {
        return {"message": "No pending requests"}
    }
    
    let request = requests[0]
    
    return {
        "id": request.id.toString(),
        "user": request.user.toString(),
        "requestType": request.requestType,
        "requestTypeName": request.requestType == 0 ? "CREATE_TIDE" : (request.requestType == 3 ? "CLOSE_TIDE" : "UNKNOWN"),
        "status": request.status,
        "statusName": request.status == 0 ? "PENDING" : (request.status == 1 ? "PROCESSING" : (request.status == 2 ? "COMPLETED" : "FAILED")),
        "tokenAddress": request.tokenAddress.toString(),
        "amount": request.amount.toString(),
        "tideId": request.tideId.toString(),
        "timestamp": request.timestamp.toString(),
        "message": request.message
    }
}