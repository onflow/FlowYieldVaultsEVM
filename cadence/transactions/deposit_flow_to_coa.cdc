import "EVM"
import "FlowToken"
import "FungibleToken"

/// @title Deposit FLOW to COA
/// @notice Deposits FLOW from Cadence account into the COA's EVM balance
/// @dev This bridges FLOW from Cadence to EVM by depositing into the COA
///
/// @param amount Amount of FLOW to deposit into the COA
///
transaction(amount: UFix64) {
    let coa: &EVM.CadenceOwnedAccount
    let sentVault: @FlowToken.Vault

    prepare(signer: auth(BorrowValue) &Account) {
        self.coa = signer.storage.borrow<&EVM.CadenceOwnedAccount>(
            from: /storage/evm
        ) ?? panic("Could not borrow COA reference")

        let vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow Flow vault reference")

        self.sentVault <- vaultRef.withdraw(amount: amount) as! @FlowToken.Vault
    }

    execute {
        self.coa.deposit(from: <-self.sentVault)
    }
}
