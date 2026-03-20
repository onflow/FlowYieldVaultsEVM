import "EVM"

/// @title Get EVM YieldVaults for User
/// @notice Reads the YieldVault IDs owned by a user from the EVM contract
/// @dev Calls the EVM contract to read getYieldVaultIdsForUser
///
/// @param contractAddress The FlowYieldVaultsRequests contract address
/// @param userAddress The user's EVM address
/// @return Array of YieldVault IDs owned by the user
///
access(all) fun main(contractAddress: String, userAddress: String): [UInt64] {
    let evmContractAddress = EVM.addressFromString(contractAddress)
    // Arbitrary "from" address for dryCall (read-only).
    let fromAddress = EVM.addressFromString("0x0000000000000000000000000000000000000001")
    let evmUserAddress = EVM.addressFromString(userAddress)

    // Read getYieldVaultIdsForUser(address)
    let result = EVM.dryCallWithSigAndArgs(
        from: fromAddress,
        to: evmContractAddress,
        signature: "getYieldVaultIdsForUser(address)",
        args: [evmUserAddress],
        gasLimit: 500_000,
        value: 0,
        resultTypes: [Type<[UInt64]>()]
    )

    if result.status == EVM.Status.successful {
        assert(result.results.length == 1, message: "Invalid response from getYieldVaultIdsForUser()")
        return result.results[0] as! [UInt64]
    }

    return []
}
