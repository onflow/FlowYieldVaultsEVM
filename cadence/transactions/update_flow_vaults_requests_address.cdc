import "FlowYieldVaultsEVM"
import "EVM"

/// @title Update FlowYieldVaultsRequests Address
/// @notice Updates the FlowYieldVaultsRequests contract address on EVM
/// @dev Requires Admin resource. Use this to update after redeployment.
///
/// @param newAddress The new EVM address of the FlowYieldVaultsRequests contract
///
transaction(newAddress: String) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowYieldVaultsEVM.Admin>(
            from: FlowYieldVaultsEVM.AdminStoragePath
        ) ?? panic("Could not borrow Admin resource")

        let evmAddress = EVM.addressFromString(newAddress)
        admin.updateFlowYieldVaultsRequestsAddress(evmAddress)
    }
}
