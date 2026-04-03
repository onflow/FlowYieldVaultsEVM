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
    // Arbitrary "from" address for dryCall (read-only).
    let fromAddress = EVM.addressFromString("0x0000000000000000000000000000000000000001")
    let evmTokenAddress = EVM.addressFromString(tokenAddress)

    // Read allowedTokens(address)
    let result = EVM.dryCallWithSigAndArgs(
        from: fromAddress,
        to: evmContractAddress,
        signature: "allowedTokens(address)",
        args: [evmTokenAddress],
        gasLimit: 100_000,
        value: 0,
        resultTypes: [Type<Bool>(), Type<UInt256>(), Type<Bool>()]
    )

    var isSupported = false
    var minimumBalance: UInt256 = 0
    var isNative = false

    if result.status == EVM.Status.successful {
        assert(result.results.length == 3, message: "Invalid response from allowedTokens()")
        isSupported = result.results[0] as! Bool
        minimumBalance = result.results[1] as! UInt256
        isNative = result.results[2] as! Bool
    }

    return TokenConfig(
        tokenAddress: tokenAddress,
        isSupported: isSupported,
        minimumBalance: minimumBalance,
        isNative: isNative
    )
}
