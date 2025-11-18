// process_requests.cdc
import "FlowVaultsEVM"

/// Transaction to process all pending requests from FlowVaultsRequests contract
/// This will create Tides for any pending CREATE_TIDE requests
///
/// Run this after users have created requests on the EVM side
///
transaction() {
    prepare(signer: auth(BorrowValue) &Account) {
        
        // Borrow the Worker from storage
        let worker = signer.storage.borrow<&FlowVaultsEVM.Worker>(
            from: FlowVaultsEVM.WorkerStoragePath
        ) ?? panic("Could not borrow Worker from storage")
        
        // Process all pending requests
        worker.processRequests()
    }
}
