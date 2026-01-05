import "EVM"

/// @title Accept Ownership
/// @notice Accepts ownership of the EVM FlowYieldVaultsRequests contract (Ownable2Step pattern)
/// @dev Must be called after transferOwnership was initiated by the previous owner.
///      This transaction borrows the COA directly to call acceptOwnership on the EVM contract.
///
/// @param contractAddress The EVM address of the FlowYieldVaultsRequests contract
///
transaction(contractAddress: String) {
    let coa: auth(EVM.Call) &EVM.CadenceOwnedAccount

    prepare(signer: auth(BorrowValue) &Account) {
        self.coa = signer.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("Could not borrow COA from /storage/evm")
    }

    execute {
        let evmAddress = EVM.addressFromString(contractAddress)

        let calldata = EVM.encodeABIWithSignature(
            "acceptOwnership()",
            []
        )

        let result = self.coa.call(
            to: evmAddress,
            data: calldata,
            gasLimit: 100_000,
            value: EVM.Balance(attoflow: 0)
        )

        assert(result.status == EVM.Status.successful, message: "acceptOwnership failed")
    }
}
