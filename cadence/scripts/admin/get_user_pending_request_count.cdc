import "EVM"

/// @title Get User Pending Request Count
/// @notice Reads the number of pending requests for a user from the EVM contract
/// @dev Calls the EVM contract to read userPendingRequestCount mapping
///
/// @param contractAddress The FlowYieldVaultsRequests contract address
/// @param userAddress The user's EVM address
/// @return The number of pending requests for the user
///
access(all) fun main(contractAddress: String, userAddress: String): UInt256 {
    let evmContractAddress = EVM.addressFromString(contractAddress)
    // Arbitrary "from" address for dryCall (read-only).
    let fromAddress = EVM.addressFromString("0x0000000000000000000000000000000000000001")
    let evmUserAddress = EVM.addressFromString(userAddress)

    // Read getUserPendingRequestCount(address)
    let result = EVM.dryCallWithSigAndArgs(
        from: fromAddress,
        to: evmContractAddress,
        signature: "getUserPendingRequestCount(address)",
        args: [evmUserAddress],
        gasLimit: 100_000,
        value: 0,
        resultTypes: [Type<UInt256>()]
    )

    if result.status == EVM.Status.successful {
        assert(result.results.length == 1, message: "Invalid response from getUserPendingRequestCount()")
        return result.results[0] as! UInt256
    }

    return 0
}
