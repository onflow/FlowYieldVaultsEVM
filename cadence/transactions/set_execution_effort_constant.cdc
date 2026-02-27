import "FlowYieldVaultsEVMWorkerOps"

/// @title Set Execution Effort Constant
/// @notice Sets a value for a given key in executionEffortConstants via the Admin resource
/// @dev Only the account with the Admin resource stored can execute this transaction.
///      Valid keys:
///      - schedulerBaseEffort: Base effort for SchedulerHandler execution
///      - schedulerPerRequestEffort: Additional effort per request preprocessed
///      - workerCreateYieldVaultRequestEffort: Effort for CREATE_YIELDVAULT requests
///      - workerDepositRequestEffort: Effort for DEPOSIT_TO_YIELDVAULT requests
///      - workerWithdrawRequestEffort: Effort for WITHDRAW_FROM_YIELDVAULT requests
///      - workerCloseYieldVaultRequestEffort: Effort for CLOSE_YIELDVAULT requests
///
/// @param key The execution effort constant key (must be one of the valid keys above)
/// @param value The execution effort value to set (must be greater than 0)
///
transaction(key: String, value: UInt64) {
    let admin: &FlowYieldVaultsEVMWorkerOps.Admin

    prepare(signer: auth(BorrowValue) &Account) {
        self.admin = signer.storage.borrow<&FlowYieldVaultsEVMWorkerOps.Admin>(
            from: FlowYieldVaultsEVMWorkerOps.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
    }

    execute {
        self.admin.setExecutionEffortConstants(key: key, value: value)
    }
}
