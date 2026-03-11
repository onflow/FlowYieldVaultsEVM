import "FlowYieldVaultsEVMWorkerOps"

/// @title Set Max Processing Requests
/// @notice Sets the maximum number of concurrent WorkerHandlers the scheduler may keep in flight
/// @dev Only the account with the Admin resource stored can execute this transaction.
///
/// @param maxProcessingRequests The maximum number of concurrent scheduled worker requests
///
transaction(maxProcessingRequests: UInt8) {
    let admin: &FlowYieldVaultsEVMWorkerOps.Admin

    prepare(signer: auth(BorrowValue) &Account) {
        self.admin = signer.storage.borrow<&FlowYieldVaultsEVMWorkerOps.Admin>(
            from: FlowYieldVaultsEVMWorkerOps.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
    }

    execute {
        self.admin.setMaxProcessingRequests(maxProcessingRequests: maxProcessingRequests)
    }
}
