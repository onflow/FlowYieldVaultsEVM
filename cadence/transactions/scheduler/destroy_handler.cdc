import "FlowYieldVaultsEVMWorkerOps"

/// @title Destroy FlowYieldVaultsEVMWorkerOps Scheduler and Worker Handlers
/// @notice Removes the Handler resource from storage
transaction() {
    prepare(signer: auth(LoadValue, UnpublishCapability) &Account) {

        // Load and destroy the SchedulerHandler resource
        if let handler <- signer.storage.load<@FlowYieldVaultsEVMWorkerOps.SchedulerHandler>(
            from: FlowYieldVaultsEVMWorkerOps.SchedulerHandlerStoragePath
        ) {
            destroy handler
        }

        // Load and destroy the WorkerHandler resource
        if let handler <- signer.storage.load<@FlowYieldVaultsEVMWorkerOps.WorkerHandler>(
            from: FlowYieldVaultsEVMWorkerOps.WorkerHandlerStoragePath
        ) {
            destroy handler
        }
    }
}
