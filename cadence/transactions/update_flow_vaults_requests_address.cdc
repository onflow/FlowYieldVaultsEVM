import "FlowVaultsEVM"
import "EVM"

/// @title Update FlowVaultsRequests Address
/// @notice Updates the FlowVaultsRequests contract address on EVM
/// @dev Requires Admin resource. Use this to update after redeployment.
///
/// @param newAddress The new EVM address of the FlowVaultsRequests contract
///
transaction(newAddress: String) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowVaultsEVM.Admin>(
            from: FlowVaultsEVM.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        let evmAddress = EVM.addressFromString(newAddress)
        admin.updateFlowVaultsRequestsAddress(evmAddress)
    }
}
