import "EVM"

/// @title Deploy EVM Contract via COA
/// @notice Deploys an EVM contract using the Cadence Owned Account
/// @dev This allows deploying EVM contracts using Google KMS signing through Cadence
///
/// @param bytecode The compiled contract bytecode (hex string without 0x prefix)
/// @param gasLimit The gas limit for the deployment transaction
///
transaction(bytecode: String, gasLimit: UInt64) {
    let coa: auth(EVM.Deploy) &EVM.CadenceOwnedAccount

    prepare(signer: auth(BorrowValue) &Account) {
        self.coa = signer.storage.borrow<auth(EVM.Deploy) &EVM.CadenceOwnedAccount>(from: /storage/evm)
            ?? panic("Could not borrow COA reference")
    }

    execute {
        // Convert hex string to bytes
        let bytecodeBytes = bytecode.decodeHex()
        
        // Deploy the contract
        let result = self.coa.deploy(
            code: bytecodeBytes,
            gasLimit: gasLimit,
            value: EVM.Balance(attoflow: 0)
        )

        // Check if deployment was successful
        assert(result.status == EVM.Status.successful, message: "EVM contract deployment failed")
    }
}
