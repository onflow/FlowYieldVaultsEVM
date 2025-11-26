import "EVM"

/// @title Check Public COA
/// @notice Validates the public COA capability for an account
/// @param address The Flow account address to check
/// @return Dictionary with capability status and COA details
///
access(all) fun main(address: Address): AnyStruct {
    let account = getAccount(address)
    let publicPath = /public/evm

    let result: {String: AnyStruct} = {}

    let evmCap = account.capabilities.get<&EVM.CadenceOwnedAccount>(publicPath)
    result["evmCapExists"] = evmCap != nil
    result["evmCapValid"] = evmCap.check()

    if let evmRef = evmCap.borrow() {
        result["coaAddress"] = evmRef.address().toString()
        result["coaBalance"] = evmRef.balance().inAttoFLOW()
        result["type"] = "Valid EVM.CadenceOwnedAccount"
    } else {
        let anyCap = account.capabilities.get<&AnyStruct>(publicPath)
        result["anyCapExists"] = anyCap != nil
        result["anyCapValid"] = anyCap.check()

        if anyCap.check() {
            result["type"] = "Valid capability but not EVM.CadenceOwnedAccount type"
        } else {
            result["type"] = "Broken/invalid capability at path"
        }
    }

    return result
}
