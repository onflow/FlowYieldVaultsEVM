import "FlowVaultsEVM"

/// Check if the Worker has a COA and get its address
access(all) fun main(workerAddress: Address): String? {
    let account = getAccount(workerAddress)
    
    // Borrow the Worker from public capability
    let workerCap = account.capabilities.get<&FlowVaultsEVM.Worker>(
        FlowVaultsEVM.WorkerPublicPath
    )
    
    if let worker = workerCap.borrow() {
        return worker.getCOAAddressString()
    }
    
    return nil
}
