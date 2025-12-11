import "FlowYieldVaultsEVM"
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
    let evmUserAddress = EVM.addressFromString(userAddress)

    // Read getUserPendingRequestCount(address)
    let calldata = EVM.encodeABIWithSignature(
        "getUserPendingRequestCount(address)",
        [evmUserAddress]
    )
    let result = evmContractAddress.call(
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
