import "EVM"

/// @title Set Token Config via COA
/// @notice Calls setTokenConfig on the FlowYieldVaultsRequests EVM contract
/// @dev This allows configuring supported tokens using Google KMS signing through Cadence
///
/// @param contractAddress The FlowYieldVaultsRequests EVM contract address (hex string with 0x prefix)
/// @param tokenAddress The token address to configure (hex string with 0x prefix)
/// @param isSupported Whether the token is supported
/// @param minimumBalance Minimum deposit amount in wei
/// @param isNative Whether this is a native token
///
transaction(
    contractAddress: String,
    tokenAddress: String,
    isSupported: Bool,
    minimumBalance: UInt256,
    isNative: Bool
) {
    let coa: auth(EVM.Call) &EVM.CadenceOwnedAccount

    prepare(signer: auth(BorrowValue) &Account) {
        self.coa = signer.storage.borrow<auth(EVM.Call) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("Could not borrow COA reference")
    }

    execute {
        let targetContract = EVM.addressFromString(contractAddress)
        let token = EVM.addressFromString(tokenAddress)

        // Call the function: setTokenConfig(address,bool,uint256,bool)
        let result = self.coa.callWithSigAndArgs(
            to: targetContract,
            signature: "setTokenConfig(address,bool,uint256,bool)",
            args: [token, isSupported, minimumBalance, isNative],
            gasLimit: 100_000,
            value: 0,
            resultTypes: nil
        )

        // Check if call was successful
        assert(result.status == EVM.Status.successful, message: "setTokenConfig call failed")
    }
}
