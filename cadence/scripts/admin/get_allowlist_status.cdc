import "FlowYieldVaultsEVM"
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

    // Read allowlistEnabled
    let enabledCalldata = EVM.encodeABIWithSignature("allowlistEnabled()", [])
    let enabledResult = evmContractAddress.call(
        data: enabledCalldata,
        gasLimit: 100_000,
        value: EVM.Balance(attoflow: 0)
    )

    var enabled = false
    if enabledResult.status == EVM.Status.successful {
        let decoded = EVM.decodeABI(types: [Type<Bool>()], data: enabledResult.data)
        enabled = decoded[0] as! Bool
    }

    // Check if address is allowlisted (if provided)
    var isAllowlisted = false
    if addressToCheck.length > 0 {
        let checkAddress = EVM.addressFromString(addressToCheck)
        let allowlistedCalldata = EVM.encodeABIWithSignature("allowlisted(address)", [checkAddress])
        let allowlistedResult = evmContractAddress.call(
            data: allowlistedCalldata,
            gasLimit: 100_000,
            value: EVM.Balance(attoflow: 0)
        )

        if allowlistedResult.status == EVM.Status.successful {
            let decoded = EVM.decodeABI(types: [Type<Bool>()], data: allowlistedResult.data)
            isAllowlisted = decoded[0] as! Bool
        }
    }

    return AllowlistStatus(
        enabled: enabled,
        addressChecked: addressToCheck,
        isAllowlisted: isAllowlisted
    )
}
