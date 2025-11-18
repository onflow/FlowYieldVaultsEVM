import "EVM"
import "FlowToken"
import "FungibleToken"

/// Transfers FLOW from Cadence account to an EVM address via COA
/// @param evmAddressHex: The hex address of the EVM account to fund (without 0x prefix)
/// @param amount: Amount of FLOW to transfer
transaction(evmAddressHex: String, amount: UFix64) {
    let coa: auth(EVM.Call) &EVM.CadenceOwnedAccount
    let sentVault: @FlowToken.Vault
    
    prepare(signer: auth(BorrowValue) &Account) {
        // Borrow COA reference with Call entitlement
        self.coa = signer.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(
            from: /storage/evm
        ) ?? panic("Could not borrow COA reference")
        
        // Withdraw FLOW from signer's vault
        let vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow Flow vault reference")
        
        self.sentVault <- vaultRef.withdraw(amount: amount) as! @FlowToken.Vault
    }
    
    execute {
        // First, deposit the FLOW into the COA
        self.coa.deposit(from: <-self.sentVault)
        
        // Convert the target EVM address from hex
        let toAddress = EVM.addressFromString(evmAddressHex)
        
        // Calculate amount in attoflow (1 FLOW = 1e18 on EVM, but UFix64 in Cadence has 8 decimals)
        // So we multiply by 1e8 first (which UFix64 can handle), then by 1e10 to reach 1e18
        let amountInAttoflow = UInt(amount * 100_000_000.0) * 10_000_000_000
        
        // Transfer from COA to target EVM address
        let result = self.coa.call(
            to: toAddress,
            data: [], // empty data for simple transfer
            gasLimit: 100_000,
            value: EVM.Balance(attoflow: amountInAttoflow)
        )
        
        // Ensure transfer was successful
        assert(
            result.status == EVM.Status.successful,
            message: "Transfer failed with error code: ".concat(result.errorCode.toString())
                .concat(" - ").concat(result.errorMessage)
        )
    }
}