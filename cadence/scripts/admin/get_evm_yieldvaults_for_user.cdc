import "FlowYieldVaultsEVM"
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
    let evmUserAddress = EVM.addressFromString(userAddress)

    // Read getYieldVaultIdsForUser(address)
    let calldata = EVM.encodeABIWithSignature(
        "getYieldVaultIdsForUser(address)",
        [evmUserAddress]
    )
    let result = evmContractAddress.call(
        data: calldata,
        gasLimit: 500_000,
        value: EVM.Balance(attoflow: 0)
    )

    if result.status == EVM.Status.successful {
        let decoded = EVM.decodeABI(types: [Type<[UInt64]>()], data: result.data)
        return decoded[0] as! [UInt64]
    }

    return []
}
