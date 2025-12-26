import "FlowYieldVaultsEVM"

/// @notice Gets pending requests for a specific EVM address
/// @param evmAddressHex The EVM address as a hex string (e.g., "0x1234...")
/// @return PendingRequestsInfo containing count, balance, and request details
access(all) fun main(evmAddressHex: String): FlowYieldVaultsEVM.PendingRequestsInfo {
    return FlowYieldVaultsEVM.getPendingRequestsForEVMAddress(evmAddressHex)
}
