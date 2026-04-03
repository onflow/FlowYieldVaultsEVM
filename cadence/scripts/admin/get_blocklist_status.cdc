import "EVM"

/// @title Get Blocklist Status
/// @notice Reads the blocklist enabled status and checks if an address is blocklisted
/// @dev Calls the EVM contract to read blocklistEnabled and blocklisted mapping
///
/// @param contractAddress The FlowYieldVaultsRequests contract address
/// @param addressToCheck Optional address to check if blocklisted (empty string to skip)
/// @return A struct containing blocklist status information
///
access(all) struct BlocklistStatus {
    access(all) let enabled: Bool
    access(all) let addressChecked: String
    access(all) let isBlocklisted: Bool

    init(enabled: Bool, addressChecked: String, isBlocklisted: Bool) {
        self.enabled = enabled
        self.addressChecked = addressChecked
        self.isBlocklisted = isBlocklisted
    }
}

access(all) fun main(contractAddress: String, addressToCheck: String): BlocklistStatus {
    let evmContractAddress = EVM.addressFromString(contractAddress)
    // Arbitrary "from" address for dryCall (read-only).
    let fromAddress = EVM.addressFromString("0x0000000000000000000000000000000000000001")

    // Read blocklistEnabled
    let enabledResult = EVM.dryCallWithSigAndArgs(
        from: fromAddress,
        to: evmContractAddress,
        signature: "blocklistEnabled()",
        args: [],
        gasLimit: 100_000,
        value: 0,
        resultTypes: [Type<Bool>()]
    )

    var enabled = false
    if enabledResult.status == EVM.Status.successful {
        assert(enabledResult.results.length == 1, message: "Invalid response from blocklistEnabled()")
        enabled = enabledResult.results[0] as! Bool
    }

    // Check if address is blocklisted (if provided)
    var isBlocklisted = false
    if addressToCheck.length > 0 {
        let checkAddress = EVM.addressFromString(addressToCheck)
        let blocklistedResult = EVM.dryCallWithSigAndArgs(
            from: fromAddress,
            to: evmContractAddress,
            signature: "blocklisted(address)",
            args: [checkAddress],
            gasLimit: 100_000,
            value: 0,
            resultTypes: [Type<Bool>()]
        )

        if blocklistedResult.status == EVM.Status.successful {
            assert(blocklistedResult.results.length == 1, message: "Invalid response from blocklisted()")
            isBlocklisted = blocklistedResult.results[0] as! Bool
        }
    }

    return BlocklistStatus(
        enabled: enabled,
        addressChecked: addressToCheck,
        isBlocklisted: isBlocklisted
    )
}
