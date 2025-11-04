// setup_worker_with_badge.cdc
import "TidalEVM"
import "TidalYieldClosedBeta"
import "EVM"

/// Combined transaction that grants beta badge to self and sets up the worker
/// Only needed once during initial setup when admin == user
///
/// @param tidalRequestsAddress: The EVM address of the TidalRequests contract
///
transaction(tidalRequestsAddress: String) {
    prepare(signer: auth(BorrowValue, SaveValue, LoadValue, Storage, Capabilities, CopyValue) &Account) {
        
        // Step 1: Grant beta badge to self if not already done
        let storagePath = TidalYieldClosedBeta.UserBetaCapStoragePath
        var betaBadgeCap: Capability<auth(TidalYieldClosedBeta.Beta) &TidalYieldClosedBeta.BetaBadge>? = nil
        
        // Check if badge capability already exists
        if signer.storage.type(at: storagePath) != nil {
            betaBadgeCap = signer.storage.copy<Capability<auth(TidalYieldClosedBeta.Beta) &TidalYieldClosedBeta.BetaBadge>>(
                from: storagePath
            )
            log("Using existing beta badge capability")
        } else {
            // Need to grant beta badge to self
            log("Granting beta badge to self...")
            
            let betaAdminHandle = signer.storage.borrow<auth(TidalYieldClosedBeta.Admin) &TidalYieldClosedBeta.AdminHandle>(
                from: TidalYieldClosedBeta.AdminHandleStoragePath
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
        
        // Get the TidalEVM Admin resource
        let admin = signer.storage.borrow<&TidalEVM.Admin>(
            from: TidalEVM.AdminStoragePath
        ) ?? panic("Could not borrow TidalEVM Admin")
        
        // Load the existing COA from standard storage path
        let coa <- signer.storage.load<@EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("Could not load COA from /storage/evm")
        
        log("Using existing COA with address: ".concat(coa.address().toString()))
        
        // Create worker with the COA and beta badge capability
        let worker <- admin.createWorker(coa: <-coa, betaBadgeCap: betaBadgeCap!)
        
        // Save worker to storage
        signer.storage.save(<-worker, to: TidalEVM.WorkerStoragePath)
        
        // Set TidalRequests contract address
        let evmAddress = EVM.addressFromString(tidalRequestsAddress)
        admin.setTidalRequestsAddress(evmAddress)
        
        log("Worker created and TidalRequests address set to: ".concat(tidalRequestsAddress))
    }
}