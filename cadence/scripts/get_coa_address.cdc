import "FlowVaultsEVM"
import "EVM"

access(all) fun main(account: Address): String {
    let worker = getAuthAccount<auth(Storage) &Account>(account)
        .storage.borrow<&FlowVaultsEVM.Worker>(from: FlowVaultsEVM.WorkerStoragePath)
        ?? panic("Worker not found")
    
    return worker.getCOAAddressString()
}