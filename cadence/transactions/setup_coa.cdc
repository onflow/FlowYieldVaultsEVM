import "EVM"

transaction() {
    prepare(signer: auth(SaveValue, IssueStorageCapabilityController, PublishCapability, BorrowValue) &Account) {
        let storagePath = /storage/evm
        let publicPath = /public/evm

        // Check if COA already exists
        if signer.storage.borrow<&EVM.CadenceOwnedAccount>(from: storagePath) == nil {
            // Create account & save to storage
            let coa: @EVM.CadenceOwnedAccount <- EVM.createCadenceOwnedAccount()
            signer.storage.save(<-coa, to: storagePath)

            // Publish a public capability to the COA
            let cap = signer.capabilities.storage.issue<&EVM.CadenceOwnedAccount>(storagePath)
            signer.capabilities.publish(cap, at: publicPath)
        } else {
            // Borrow a reference to the COA from the storage location we saved it to
            let coa = signer.storage.borrow<&EVM.CadenceOwnedAccount>(from: storagePath) ?? 
                                                panic("Could not borrow reference to the signer's CadenceOwnedAccount (COA). "
                                                .concat("Ensure the signer account has a COA stored in the canonical /storage/evm path"))
        }
    }
}