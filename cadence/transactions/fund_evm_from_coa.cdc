import "EVM"
import "FlowToken"
import "FungibleToken"

/// @title Fund EVM from COA
/// @notice Transfers FLOW from Cadence account to an EVM address via COA
/// @dev Deposits FLOW into COA first, then transfers to target EVM address.
///
/// @param evmAddressHex The hex address of the EVM account to fund (with or without 0x prefix)
/// @param amount Amount of FLOW to transfer
///
transaction(evmAddressHex: String, amount: UFix64) {
    let coa: auth(EVM.Call) &EVM.CadenceOwnedAccount
    let sentVault: @FlowToken.Vault

    prepare(signer: auth(BorrowValue) &Account) {
        self.coa = signer.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(
            from: /storage/evm
        ) ?? panic("Could not borrow COA reference")

        let vaultRef = signer.storage.borrow<auth(FungibleToken.Withdraw) &FlowToken.Vault>(
            from: /storage/flowTokenVault
        ) ?? panic("Could not borrow Flow vault reference")

        self.sentVault <- vaultRef.withdraw(amount: amount) as! @FlowToken.Vault
    }

    execute {
        self.coa.deposit(from: <-self.sentVault)

        let toAddress = EVM.addressFromString(evmAddressHex)
        let amountInAttoflow = UInt(amount * 100_000_000.0) * 10_000_000_000

        let result = self.coa.call(
            to: toAddress,
            data: [],
            gasLimit: 100_000,
            value: EVM.Balance(attoflow: amountInAttoflow)
        )

        assert(
            result.status == EVM.Status.successful,
            message: "Transfer failed: ".concat(result.errorMessage)
        )
    }
}
