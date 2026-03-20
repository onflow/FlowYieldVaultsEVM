import "EVM"

/// @title Get Allowlist Status
/// @notice Reads the allowlist enabled status and checks if an address is allowlisted
/// @dev Calls the EVM contract to read allowlistEnabled and allowlisted mapping
///
/// @param contractAddress The FlowYieldVaultsRequests contract address
/// @param addressToCheck Optional address to check if allowlisted (empty string to skip)
/// @return A struct containing allowlist status information
///
access(all) struct AllowlistStatus {
    access(all) let enabled: Bool
    access(all) let addressChecked: String
    access(all) let isAllowlisted: Bool

    init(enabled: Bool, addressChecked: String, isAllowlisted: Bool) {
        self.enabled = enabled
        self.addressChecked = addressChecked
        self.isAllowlisted = isAllowlisted
    }
}

access(all) fun main(contractAddress: String, addressToCheck: String): AllowlistStatus {
    let evmContractAddress = EVM.addressFromString(contractAddress)
    // Arbitrary "from" address for dryCall (read-only).
    let fromAddress = EVM.addressFromString("0x0000000000000000000000000000000000000001")

    // Read allowlistEnabled
    let enabledResult = EVM.dryCallWithSigAndArgs(
        from: fromAddress,
        to: evmContractAddress,
        signature: "allowlistEnabled()",
        args: [],
        gasLimit: 100_000,
        value: 0,
        resultTypes: [Type<Bool>()]
    )

    var enabled = false
    if enabledResult.status == EVM.Status.successful {
        assert(enabledResult.results.length == 1, message: "Invalid response from allowlistEnabled()")
        enabled = enabledResult.results[0] as! Bool
    }

    // Check if address is allowlisted (if provided)
    var isAllowlisted = false
    if addressToCheck.length > 0 {
        let checkAddress = EVM.addressFromString(addressToCheck)
        let allowlistedResult = EVM.dryCallWithSigAndArgs(
            from: fromAddress,
            to: evmContractAddress,
            signature: "allowlisted(address)",
            args: [checkAddress],
            gasLimit: 100_000,
            value: 0,
            resultTypes: [Type<Bool>()]
        )

        if allowlistedResult.status == EVM.Status.successful {
            assert(allowlistedResult.results.length == 1, message: "Invalid response from allowlisted()")
            isAllowlisted = allowlistedResult.results[0] as! Bool
        }
    }

    return AllowlistStatus(
        enabled: enabled,
        addressChecked: addressToCheck,
        isAllowlisted: isAllowlisted
    )
}
