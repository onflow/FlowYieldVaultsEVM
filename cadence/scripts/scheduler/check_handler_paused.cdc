import "FlowYieldVaultsEVMWorkerOps"

/// @title Check Scheduler Handler Paused
/// @notice Returns whether the scheduler handler is currently paused
/// @return True if paused, false otherwise
///
access(all) fun main(): Bool {
    return FlowYieldVaultsEVMWorkerOps.getIsSchedulerPaused()
}
