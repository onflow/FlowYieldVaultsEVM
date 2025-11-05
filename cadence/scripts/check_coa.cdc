// check_coa.cdc
import "EVM"

access(all) fun main(address: Address): String {
    let account = getAccount(address)
    
    // Check if COA exists at standard path
    let coaType = account.storage.type(at: /storage/evm)
    
    if coaType == nil {
        return "❌ No COA found at /storage/evm"
    }
    
    return "✅ COA exists at /storage/evm with type: ".concat(coaType!.identifier)
}