import "FlowVaultsTransactionHandler"

/// Unpause the automated transaction handler
/// After unpausing, you'll need to manually schedule a new execution
/// using schedule_initial_flow_vaults_execution.cdc
transaction() {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowVaultsTransactionHandler.Admin>(
            from: FlowVaultsTransactionHandler.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        admin.unpause()
        
        log("✅ Handler unpaused successfully")
        log("📝 To resume automated processing, run:")
        log("   flow transactions send cadence/transactions/schedule_initial_flow_vaults_execution.cdc \\")
        log("     10.0 1 7499 --network testnet --signer testnet-account")
    }
}
