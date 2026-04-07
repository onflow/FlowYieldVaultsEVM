import "EVM"
import "FlowYieldVaultsEVM"

transaction(tokenAddress: String) {
    prepare(signer: auth(BorrowValue) &Account) {
        let coaRef = signer.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(
            from: /storage/evm
        ) ?? panic("Could not borrow COA reference")

        let transferCalldata = EVM.encodeABIWithSignature(
            "transfer(address,uint256)",
            [
                EVM.addressFromString("0x0000000000000000000000000000000000000099"),
                1 as UInt256
            ]
        )

        let transferResult = coaRef.call(
            to: EVM.addressFromString(tokenAddress),
            data: transferCalldata,
            gasLimit: 100_000,
            value: EVM.Balance(attoflow: 0)
        )

        assert(
            transferResult.status == EVM.Status.successful,
            message: "Expected transfer call to succeed at the EVM level"
        )
        assert(
            !FlowYieldVaultsEVM.isERC20BoolReturnSuccess(transferResult.data),
            message: "Expected transfer(false) return data to be rejected"
        )
    }
}
