import "FlowVaultsEVM"

/// @title Check User Tides
/// @notice Returns the Tide IDs owned by an EVM address
/// @param evmAddress The EVM address (with or without 0x prefix)
/// @return Array of Tide IDs owned by the user
///
access(all) fun main(evmAddress: String): [UInt64] {
    var normalizedAddress = evmAddress.toLower()
    if normalizedAddress.length > 2 && normalizedAddress.slice(from: 0, upTo: 2) == "0x" {
        normalizedAddress = normalizedAddress.slice(from: 2, upTo: normalizedAddress.length)
    }

    while normalizedAddress.length < 40 {
        normalizedAddress = "0".concat(normalizedAddress)
    }

    return FlowVaultsEVM.getTideIDsForEVMAddress(normalizedAddress)
}
