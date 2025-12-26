import "EVM"

/// @title Approve ERC20 Token Spending from COA
/// @notice Approves a spender to transfer ERC20 tokens from the COA
/// @dev Calls the ERC20 approve(address,uint256) function on the token contract.
///      Used to allow FlowYieldVaultsRequests contract to pull tokens back from COA
///      when refunding failed CREATE/DEPOSIT requests.
///
/// @param tokenAddressHex The ERC20 token contract address (e.g., WFLOW)
/// @param spenderAddressHex The address to approve (e.g., FlowYieldVaultsRequests contract)
/// @param amount The amount to approve (in wei/smallest unit)
///
transaction(tokenAddressHex: String, spenderAddressHex: String, amount: UInt256) {
    let coa: auth(EVM.Call) &EVM.CadenceOwnedAccount

    prepare(signer: auth(BorrowValue) &Account) {
        self.coa = signer.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(
            from: /storage/evm
        ) ?? panic("Could not borrow COA reference")
    }

    execute {
        let tokenAddress = EVM.addressFromString(tokenAddressHex)
        let spenderAddress = EVM.addressFromString(spenderAddressHex)

        // Encode approve(address,uint256) call using EVM.encodeABIWithSignature
        let calldata = EVM.encodeABIWithSignature(
            "approve(address,uint256)",
            [spenderAddress, amount]
        )

        let result = self.coa.call(
            to: tokenAddress,
            data: calldata,
            gasLimit: 100_000,
            value: EVM.Balance(attoflow: 0)
        )

        assert(
            result.status == EVM.Status.successful,
            message: "ERC20 approve failed: \(result.errorMessage)"
        )
    }
}
