/// @title Check Storage
/// @notice Lists all storage paths and their types for an account
/// @param address The Flow account address to inspect
/// @return Array of storage path to type mappings
///
access(all) fun main(address: Address): [String] {
    let account = getAccount(address)
    var paths: [String] = []

    account.storage.forEachStored(fun (path: StoragePath, type: Type): Bool {
        paths.append(path.toString().concat(" -> ").concat(type.identifier))
        return true
    })

    return paths
}
