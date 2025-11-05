import "TidalEVM"
import "EVM"

transaction(newAddress: String) {
    prepare(acct: auth(Storage) &Account) {
        let admin = acct.storage.borrow<&TidalEVM.Admin>(
            from: TidalEVM.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        let evmAddress = EVM.addressFromString(newAddress)
        admin.updateTidalRequestsAddress(evmAddress)  // 👈 Nouvelle fonction
        
        log("TidalRequests address updated to: ".concat(newAddress))
    }
}