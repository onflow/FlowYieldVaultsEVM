import "FlowVaultsTransactionHandler"

/// @title Update Threshold To Delay
/// @notice Updates the mapping of pending request thresholds to execution delays
/// @dev Requires Admin resource. Each threshold maps to a delay in seconds.
///      Higher pending counts should map to shorter delays for faster processing.
///
/// @param newThresholds New mapping of thresholds to delays (e.g., {50: 5.0, 20: 15.0, 10: 30.0, 5: 45.0, 0: 60.0})
///
transaction(newThresholds: {Int: UFix64}) {
    prepare(signer: auth(BorrowValue) &Account) {
        let admin = signer.storage.borrow<&FlowVaultsTransactionHandler.Admin>(
            from: FlowVaultsTransactionHandler.AdminStoragePath
        ) ?? panic("Could not borrow Admin from storage")

        admin.setThresholdToDelay(newThresholds: newThresholds)
    }
}
