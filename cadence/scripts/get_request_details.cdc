import "FlowVaultsEVM"

/// @title Get Request Details
/// @notice Returns details of the first pending request from FlowVaultsRequests
/// @param contractAddr The address where FlowVaultsEVM Worker is stored
/// @param startIndex The index to start fetching requests from
/// @param count The number of requests to fetch
/// @return Dictionary with request details or empty message if none pending
///
access(all) fun main(contractAddr: Address, startIndex: Int, count: Int): {String: AnyStruct} {
    let account = getAuthAccount<auth(Storage) &Account>(contractAddr)

    let worker = account.storage.borrow<&FlowVaultsEVM.Worker>(
        from: FlowVaultsEVM.WorkerStoragePath
    ) ?? panic("No Worker found")

    let requests = worker.getPendingRequestsFromEVM(startIndex: startIndex, count: count)

    if requests.length == 0 {
        return {"message": "No pending requests"}
    }

    let request = requests[0]

    return {
        "id": request.id.toString(),
        "user": request.user.toString(),
        "requestType": request.requestType,
        "requestTypeName": getRequestTypeName(request.requestType),
        "status": request.status,
        "statusName": getStatusName(request.status),
        "tokenAddress": request.tokenAddress.toString(),
        "amount": request.amount.toString(),
        "tideId": request.tideId.toString(),
        "timestamp": request.timestamp.toString(),
        "message": request.message
    }
}

access(all) fun getRequestTypeName(_ requestType: UInt8): String {
    switch requestType {
        case 0: return "CREATE_TIDE"
        case 1: return "DEPOSIT_TO_TIDE"
        case 2: return "WITHDRAW_FROM_TIDE"
        case 3: return "CLOSE_TIDE"
        default: return "UNKNOWN"
    }
}

access(all) fun getStatusName(_ status: UInt8): String {
    switch status {
        case 0: return "PENDING"
        case 1: return "PROCESSING"
        case 2: return "COMPLETED"
        case 3: return "FAILED"
        default: return "UNKNOWN"
    }
}
