import "FlowYieldVaultsEVMWorkerOps"

/// @title Get Execution Effort Constants
/// @notice Returns the current execution effort constants from FlowYieldVaultsEVMWorkerOps
/// @dev Keys:
///      - schedulerBaseEffort: Base effort for SchedulerHandler execution
///      - schedulerPerRequestEffort: Additional effort per request preprocessed
///      - workerCreateYieldVaultRequestEffort: Effort for CREATE_YIELDVAULT requests
///      - workerDepositRequestEffort: Effort for DEPOSIT_TO_YIELDVAULT requests
///      - workerWithdrawRequestEffort: Effort for WITHDRAW_FROM_YIELDVAULT requests
///      - workerCloseYieldVaultRequestEffort: Effort for CLOSE_YIELDVAULT requests
/// @return Dictionary containing all execution effort constant key-value pairs
///
access(all) fun main(): {String: UInt64} {
    let constants = FlowYieldVaultsEVMWorkerOps.executionEffortConstants
    let result: {String: UInt64} = {}
    for key in constants.keys {
        result[key] = constants[key]!
    }
    return result
}
