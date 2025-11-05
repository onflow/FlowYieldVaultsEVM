import "TidalEVM"
import "EVM"

access(all) fun main(account: Address): String {
    let worker = getAuthAccount<auth(Storage) &Account>(account)
        .storage.borrow<&TidalEVM.Worker>(from: TidalEVM.WorkerStoragePath)
        ?? panic("Worker not found")
    
    return worker.getCOAAddressString()
}