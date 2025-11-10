import "EVM"

access(all) fun main(account: Address): String {
    let acct = getAuthAccount<auth(Storage) &Account>(account)
    
    // Borrow the COA from the standard EVM storage path
    let coa = acct.storage.borrow<&EVM.CadenceOwnedAccount>(
        from: /storage/evm
    ) ?? panic("COA not found at /storage/evm")
    
    return coa.address().toString()
}