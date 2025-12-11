import "FlowYieldVaultsEVM"
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

    // Read blocklistEnabled
    let enabledCalldata = EVM.encodeABIWithSignature("blocklistEnabled()", [])
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

    // Check if address is blocklisted (if provided)
    var isBlocklisted = false
    if addressToCheck.length > 0 {
        let checkAddress = EVM.addressFromString(addressToCheck)
        let blocklistedCalldata = EVM.encodeABIWithSignature("blocklisted(address)", [checkAddress])
        let blocklistedResult = evmContractAddress.call(
            data: blocklistedCalldata,
            gasLimit: 100_000,
            value: EVM.Balance(attoflow: 0)
        )

        if blocklistedResult.status == EVM.Status.successful {
            let decoded = EVM.decodeABI(types: [Type<Bool>()], data: blocklistedResult.data)
            isBlocklisted = decoded[0] as! Bool
        }
    }

    return BlocklistStatus(
        enabled: enabled,
        addressChecked: addressToCheck,
        isBlocklisted: isBlocklisted
    )
}
