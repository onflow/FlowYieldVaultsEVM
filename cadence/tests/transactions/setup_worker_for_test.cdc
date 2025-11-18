import "FlowVaultsEVM"
import "FlowVaultsClosedBeta"
import "EVM"

/// Test-specific Worker setup transaction for FlowVaultsEVM
/// This version doesn't set the FlowVaultsRequests address since it may already be set in tests
///
transaction() {
    prepare(signer: auth(BorrowValue, SaveValue, LoadValue, Storage, Capabilities, CopyValue) &Account) {
                
        // ========================================
        // Step 1: Get or create beta badge capability
        // ========================================
        
        var betaBadgeCap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>? = nil
        
        // First, try to find existing beta badge in standard storage path
        let standardStoragePath = FlowVaultsClosedBeta.UserBetaCapStoragePath
        if signer.storage.type(at: standardStoragePath) != nil {
            betaBadgeCap = signer.storage.copy<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(
                from: standardStoragePath
            )
        }
        
        // If not found in standard path, try the specific user path
        if betaBadgeCap == nil {
            let userSpecificPath = /storage/FlowVaultsUserBetaCap_0x3bda2f90274dbc9b
            if signer.storage.type(at: userSpecificPath) != nil {
                betaBadgeCap = signer.storage.copy<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(
                    from: userSpecificPath
                )
            }
        }
        
        // If still no beta badge found, create a new one (requires Admin)
        if betaBadgeCap == nil {            
            let betaAdminHandle = signer.storage.borrow<auth(FlowVaultsClosedBeta.Admin) &FlowVaultsClosedBeta.AdminHandle>(
                from: FlowVaultsClosedBeta.AdminHandleStoragePath
            ) ?? panic("Could not borrow AdminHandle - you need admin access or an existing beta badge")
            
            betaBadgeCap = betaAdminHandle.grantBeta(addr: signer.address)
            signer.storage.save(betaBadgeCap!, to: standardStoragePath)
        }
        
        // Verify the capability is valid
        let betaRef = betaBadgeCap!.borrow()
            ?? panic("Beta badge capability does not contain correct reference")
        
        // ========================================
        // Step 2: Setup the Worker
        // ========================================
        
        let admin = signer.storage.borrow<&FlowVaultsEVM.Admin>(
            from: FlowVaultsEVM.AdminStoragePath
        ) ?? panic("Could not borrow FlowVaultsEVM Admin")
        
        // Get COA capability (COA should already exist in storage from setup_coa transaction)
        let coaCap = signer.capabilities.storage.issue<auth(EVM.Call, EVM.Withdraw) &EVM.CadenceOwnedAccount>(
            /storage/evm
        )
        
        // Verify COA capability is valid
        let coaRef = coaCap.borrow()
            ?? panic("Could not borrow COA capability - ensure COA is set up first")
                
        // Create worker with the COA capability and beta badge capability
        let worker <- admin.createWorker(coaCap: coaCap, betaBadgeCap: betaBadgeCap!)
        
        // Save worker to storage
        signer.storage.save(<-worker, to: FlowVaultsEVM.WorkerStoragePath)
    }
}
