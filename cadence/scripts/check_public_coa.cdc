import "EVM"

access(all) fun main(address: Address): AnyStruct {
    let account = getAccount(address)
    let publicPath = /public/evm
    
    let result: {String: AnyStruct} = {}
    
    // Check with the expected type first
    let evmCap = account.capabilities.get<&EVM.CadenceOwnedAccount>(publicPath)
    result["evmCapExists"] = evmCap != nil
    result["evmCapValid"] = evmCap.check()
    
    if let evmRef = evmCap.borrow() {
        result["coaAddress"] = evmRef.address().toString()
        result["coaBalance"] = evmRef.balance().inAttoFLOW()
        result["type"] = "Valid EVM.CadenceOwnedAccount"
    } else {
        // Try as generic AnyStruct to see if SOMETHING exists
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