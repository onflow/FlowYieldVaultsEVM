// check_storage.cdc
access(all) fun main(address: Address): [String] {
    let account = getAccount(address)
    var paths: [String] = []
    
    // Iterate through storage
    account.storage.forEachStored(fun (path: StoragePath, type: Type): Bool {
        paths.append(path.toString().concat(" -> ").concat(type.identifier))
        return true
    })
    
    return paths
}