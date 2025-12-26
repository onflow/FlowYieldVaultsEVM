import "FlowYieldVaultsTransactionHandler"

/// @title Update Threshold To Delay
/// @notice Updates the mapping of pending request thresholds to execution delays
/// @dev Requires Admin resource. Each threshold maps to a delay in seconds.
///      Higher pending counts should map to shorter delays for faster processing.
///
/// @param newThresholds New mapping of thresholds to delays (e.g., {11: 3.0, 5: 5.0, 1: 7.0, 0: 30.0})
///
transaction(newThresholds: {Int: UFix64}) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowYieldVaultsTransactionHandler.Admin>(
            from: FlowYieldVaultsTransactionHandler.AdminStoragePath
        ) ?? panic("Could not borrow Admin from storage")

        admin.setThresholdToDelay(newThresholds: newThresholds)
    }
}
