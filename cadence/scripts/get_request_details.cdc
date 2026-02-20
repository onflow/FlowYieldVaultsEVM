import "FlowYieldVaultsEVM"

/// @title Get Request Details
/// @notice Returns details for a specific request ID from FlowYieldVaultsRequests
/// @param requestId The request ID to fetch
/// @return Dictionary with request details
///
access(all) fun main(requestId: UInt256): {String: AnyStruct} {

    if let request = FlowYieldVaultsEVM.getRequestUnpacked(requestId) {
        return {
            "id": request.id.toString(),
            "user": request.user.toString(),
            "requestType": request.requestType,
            "requestTypeName": getRequestTypeName(request.requestType),
            "status": getStatusName(request.status),
            "statusName": getStatusName(request.status),
            "tokenAddress": request.tokenAddress.toString(),
            "amount": request.amount.toString(),
            "yieldVaultId": request.yieldVaultId?.toString() ?? "",
            "timestamp": request.timestamp.toString(),
            "message": request.message
        }
    } else {
        panic("Request not found")
    }
}

access(all) fun getRequestTypeName(_ requestType: UInt8): String {
    switch requestType {
        case 0: return "CREATE_YIELDVAULT"
        case 1: return "DEPOSIT_TO_YIELDVAULT"
        case 2: return "WITHDRAW_FROM_YIELDVAULT"
        case 3: return "CLOSE_YIELDVAULT"
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
