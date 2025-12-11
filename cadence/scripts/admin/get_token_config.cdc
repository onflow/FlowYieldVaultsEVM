import "FlowYieldVaultsEVM"
import "EVM"

/// @title Get Token Config
/// @notice Reads the configuration for a specific token from the EVM contract
/// @dev Calls the EVM contract to read allowedTokens mapping
///
/// @param contractAddress The FlowYieldVaultsRequests contract address
/// @param tokenAddress The token address to query
/// @return A struct containing token configuration
///
access(all) struct TokenConfig {
    access(all) let tokenAddress: String
    access(all) let isSupported: Bool
    access(all) let minimumBalance: UInt256
    access(all) let isNative: Bool

    init(tokenAddress: String, isSupported: Bool, minimumBalance: UInt256, isNative: Bool) {
        self.tokenAddress = tokenAddress
        self.isSupported = isSupported
        self.minimumBalance = minimumBalance
        self.isNative = isNative
    }
}

access(all) fun main(contractAddress: String, tokenAddress: String): TokenConfig {
    let evmContractAddress = EVM.addressFromString(contractAddress)
    let evmTokenAddress = EVM.addressFromString(tokenAddress)

    // Read allowedTokens(address)
    let calldata = EVM.encodeABIWithSignature("allowedTokens(address)", [evmTokenAddress])
    let result = evmContractAddress.call(
        data: calldata,
        gasLimit: 100_000,
        value: EVM.Balance(attoflow: 0)
    )

    var isSupported = false
    var minimumBalance: UInt256 = 0
    var isNative = false

    if result.status == EVM.Status.successful {
        let decoded = EVM.decodeABI(
            types: [Type<Bool>(), Type<UInt256>(), Type<Bool>()],
            data: result.data
        )
        isSupported = decoded[0] as! Bool
        minimumBalance = decoded[1] as! UInt256
        isNative = decoded[2] as! Bool
    }

    return TokenConfig(
        tokenAddress: tokenAddress,
        isSupported: isSupported,
        minimumBalance: minimumBalance,
        isNative: isNative
    )
}
