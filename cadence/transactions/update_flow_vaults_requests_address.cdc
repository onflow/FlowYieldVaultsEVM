import "FlowVaultsEVM"
import "EVM"

transaction(newAddress: String) {
    prepare(acct: auth(Storage) &Account) {
        let admin = acct.storage.borrow<&FlowVaultsEVM.Admin>(
            from: FlowVaultsEVM.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")
        
        let evmAddress = EVM.addressFromString(newAddress)
        admin.updateFlowVaultsRequestsAddress(evmAddress)
    }
}