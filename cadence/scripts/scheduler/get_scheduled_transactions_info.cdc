import "FlowTransactionScheduler"
import "FlowTransactionSchedulerUtils"
import "FlowYieldVaultsEVMWorkerOps"

/// @title Get Scheduled Transactions Info
/// @notice Returns the status of all scheduled transactions
/// @param accountAddress: The address of the account to get the manager from
///
access(all) fun main(accountAddress: Address) {
    let account = getAuthAccount<auth(BorrowValue) &Account>(accountAddress)
    let manager = account.storage
            .borrow<&{FlowTransactionSchedulerUtils.Manager}>
            (from: FlowTransactionSchedulerUtils.managerStoragePath)

    let transactionIDs = manager!.getTransactionIDs()

    for transactionID in transactionIDs {
        let status = manager!.getTransactionStatus(id: transactionID)
        let statusString = getStatusString(status: status)
        log("\(transactionID): \(statusString)")
    }

}

access(self) fun getStatusString(status: FlowTransactionScheduler.Status?): String {
    if status == nil {
        return "nil"
    }
    switch status! {
        case FlowTransactionScheduler.Status.Scheduled:
            return "Scheduled"
        case FlowTransactionScheduler.Status.Executed:
            return "Executed"
        case FlowTransactionScheduler.Status.Canceled:
            return "Canceled"
    }
    return "unknown"
}
