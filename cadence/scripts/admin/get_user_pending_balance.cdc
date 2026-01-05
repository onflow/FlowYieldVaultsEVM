import "EVM"

/// @title Get User Pending Balance
/// @notice Reads the escrowed balance for a user and token from the EVM contract
/// @dev Calls the EVM contract to read pendingUserBalances mapping
///
/// @param contractAddress The FlowYieldVaultsRequests contract address
/// @param userAddress The user's EVM address
/// @param tokenAddress The token address to query
/// @return The user's pending balance for the specified token (in wei)
///
access(all) fun main(contractAddress: String, userAddress: String, tokenAddress: String): UInt256 {
    let evmContractAddress = EVM.addressFromString(contractAddress)
    // Arbitrary "from" address for dryCall (read-only).
    let fromAddress = EVM.addressFromString("0x0000000000000000000000000000000000000001")
    let evmUserAddress = EVM.addressFromString(userAddress)
    let evmTokenAddress = EVM.addressFromString(tokenAddress)

    // Read getUserPendingBalance(address, address)
    let calldata = EVM.encodeABIWithSignature(
        "getUserPendingBalance(address,address)",
        [evmUserAddress, evmTokenAddress]
    )
    let result = EVM.dryCall(
        from: fromAddress,
        to: evmContractAddress,
        data: calldata,
        gasLimit: 100_000,
        value: EVM.Balance(attoflow: 0)
    )

    if result.status == EVM.Status.successful {
        let decoded = EVM.decodeABI(types: [Type<UInt256>()], data: result.data)
        return decoded[0] as! UInt256
    }

    return 0
}
