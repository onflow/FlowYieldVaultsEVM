import "EVM"

/// @title Setup COA
/// @notice Creates a Cadence Owned Account (COA) for EVM interactions
/// @dev Sets up COA at /storage/evm with public capability at /public/evm.
///      Idempotent: safe to run multiple times.
///
transaction() {
    prepare(signer: auth(SaveValue, IssueStorageCapabilityController, PublishCapability, BorrowValue) &Account) {
        let storagePath = /storage/evm
        let publicPath = /public/evm

        if signer.storage.borrow<&EVM.CadenceOwnedAccount>(from: storagePath) == nil {
            let coa: @EVM.CadenceOwnedAccount <- EVM.createCadenceOwnedAccount()
            signer.storage.save(<-coa, to: storagePath)

            let cap = signer.capabilities.storage.issue<&EVM.CadenceOwnedAccount>(storagePath)
            signer.capabilities.publish(cap, at: publicPath)
        }
    }
}
