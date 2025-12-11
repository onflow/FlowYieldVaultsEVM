import "FlowYieldVaultsEVM"
import "EVM"

/// @title Set Token Config
/// @notice Configures a token on the EVM FlowYieldVaultsRequests contract
/// @dev Requires Worker resource. The Worker's COA must be the owner of the Solidity contract.
///
/// @param tokenAddress The EVM address of the token to configure
/// @param isSupported Whether the token is supported for deposits
/// @param minimumBalance The minimum balance required for deposits (in wei)
/// @param isNative Whether this token represents native $FLOW
///
transaction(tokenAddress: String, isSupported: Bool, minimumBalance: UInt256, isNative: Bool) {
    prepare(signer: auth(BorrowValue) &Account) {
        let worker = signer.storage.borrow<&FlowYieldVaultsEVM.Worker>(
            from: FlowYieldVaultsEVM.WorkerStoragePath
        ) ?? panic("Could not borrow FlowYieldVaultsEVM Worker resource")

        let evmTokenAddress = EVM.addressFromString(tokenAddress)

        worker.setTokenConfig(
            tokenAddress: evmTokenAddress,
            isSupported: isSupported,
            minimumBalance: minimumBalance,
            isNative: isNative
        )
    }
}
