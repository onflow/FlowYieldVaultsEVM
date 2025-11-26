import "EVM"

/// @title Check COA
/// @notice Checks if a Cadence Owned Account exists at the standard path
/// @param address The Flow account address to check
/// @return Status message indicating COA existence
///
access(all) fun main(address: Address): String {
    let account = getAccount(address)
    let coaType = account.storage.type(at: /storage/evm)

    if coaType == nil {
        return "No COA found at /storage/evm"
    }

    return "COA exists at /storage/evm with type: ".concat(coaType!.identifier)
}
