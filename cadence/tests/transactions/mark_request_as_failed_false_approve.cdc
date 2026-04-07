import "EVM"
import "FlowYieldVaultsEVM"

transaction(tokenAddress: String) {
    prepare(signer: auth(BorrowValue) &Account) {
        let worker = signer.storage.borrow<&FlowYieldVaultsEVM.Worker>(
            from: FlowYieldVaultsEVM.WorkerStoragePath
        ) ?? panic("Could not borrow FlowYieldVaultsEVM worker")

        // Any failed CREATE or DEPOSIT request with a non-native token and a positive
        // amount enters the refund approval path inside completeProcessing(...).
        let request = FlowYieldVaultsEVM.EVMRequest(
            id: 4242,
            user: EVM.addressFromString("0x0000000000000000000000000000000000000099"),
            requestType: FlowYieldVaultsEVM.RequestType.CREATE_YIELDVAULT.rawValue,
            status: FlowYieldVaultsEVM.RequestStatus.PROCESSING.rawValue,
            tokenAddress: EVM.addressFromString(tokenAddress),
            amount: 1,
            yieldVaultId: nil,
            timestamp: 0,
            message: "",
            vaultIdentifier: "",
            strategyIdentifier: ""
        )

        // The regression is fixed only if this returns false after approve(false)
        // instead of letting the request look successfully completed.
        let result = worker.markRequestAsFailed(
            request,
            message: "Synthetic failure before refund approval"
        )

        assert(!result, message: "Expected approve(false) refund path to return false")
    }
}
