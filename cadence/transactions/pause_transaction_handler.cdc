import "FlowVaultsTransactionHandler"

/// Pause the automated transaction handler
/// When paused, scheduled executions will run but skip processing
/// and will NOT schedule the next execution, breaking the chain
transaction() {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowVaultsTransactionHandler.Admin>(
            from: FlowVaultsTransactionHandler.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        admin.pause()
    }
}
