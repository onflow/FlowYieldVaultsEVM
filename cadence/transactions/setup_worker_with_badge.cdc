// setup_worker_with_badge.cdc
import "FlowVaultsEVM"
import "FlowVaultsClosedBeta"
import "EVM"

/// Combined transaction that grants beta badge to self and sets up the worker
/// Only needed once during initial setup when admin == user
///
/// @param flowVaultsRequestsAddress: The EVM address of the FlowVaultsRequests contract
///
transaction(flowVaultsRequestsAddress: String) {
    prepare(signer: auth(BorrowValue, SaveValue, LoadValue, Storage, Capabilities, CopyValue) &Account) {
        
        // Step 1: Grant beta badge to self if not already done
        let storagePath = FlowVaultsClosedBeta.UserBetaCapStoragePath
        var betaBadgeCap: Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>? = nil
        
        // Check if badge capability already exists
        if signer.storage.type(at: storagePath) != nil {
            betaBadgeCap = signer.storage.copy<Capability<auth(FlowVaultsClosedBeta.Beta) &FlowVaultsClosedBeta.BetaBadge>>(
                from: storagePath
            )
            log("Using existing beta badge capability")
        } else {
            // Need to grant beta badge to self
            log("Granting beta badge to self...")
            
            let betaAdminHandle = signer.storage.borrow<auth(FlowVaultsClosedBeta.Admin) &FlowVaultsClosedBeta.AdminHandle>(
                from: FlowVaultsClosedBeta.AdminHandleStoragePath
            ) ?? panic("Could not borrow AdminHandle")
            
            // Grant beta access to self
            betaBadgeCap = betaAdminHandle.grantBeta(addr: signer.address)
            
            // Save the capability for future use
            signer.storage.save(betaBadgeCap!, to: storagePath)
            log("Beta badge capability created and saved")
        }
        
        // Verify the capability is valid
        let betaRef = betaBadgeCap!.borrow()
            ?? panic("Beta badge capability does not contain correct reference")
        log("Beta badge verified for address: ".concat(betaRef.getOwner().toString()))
        
        // Step 2: Setup the Worker
        
        // Get the FlowVaultsEVM Admin resource
        let admin = signer.storage.borrow<&FlowVaultsEVM.Admin>(
            from: FlowVaultsEVM.AdminStoragePath
        ) ?? panic("Could not borrow FlowVaultsEVM Admin")
        
        // Load the existing COA from standard storage path
        let coa <- signer.storage.load<@EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("Could not load COA from /storage/evm")
        
        log("Using existing COA with address: ".concat(coa.address().toString()))
        
        // Create worker with the COA and beta badge capability
        let worker <- admin.createWorker(coa: <-coa, betaBadgeCap: betaBadgeCap!)
        
        // Save worker to storage
        signer.storage.save(<-worker, to: FlowVaultsEVM.WorkerStoragePath)
        
        // Set FlowVaultsRequests contract address
        let evmAddress = EVM.addressFromString(flowVaultsRequestsAddress)
        admin.setFlowVaultsRequestsAddress(evmAddress)
        
        log("Worker created and FlowVaultsRequests address set to: ".concat(flowVaultsRequestsAddress))
    }
}