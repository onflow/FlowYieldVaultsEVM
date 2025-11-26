import "EVM"

/// @title Get COA Address
/// @notice Returns the EVM address of a COA stored at the standard path
/// @param account The Flow account address to query
/// @return The EVM address as a hex string
///
access(all) fun main(account: Address): String {
    let acct = getAuthAccount<auth(Storage) &Account>(account)

    let coa = acct.storage.borrow<&EVM.CadenceOwnedAccount>(
        from: /storage/evm
    ) ?? panic("COA not found at /storage/evm")

    return coa.address().toString()
}
