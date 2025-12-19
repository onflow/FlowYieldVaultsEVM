import "FlowYieldVaultsEVM"

/// @title Get Max Requests Config
/// @notice Returns the current maxRequestsPerTx value and throughput estimates
/// @return Dictionary with current config and throughput calculations
///
access(all) fun main(): {String: AnyStruct} {
    let maxRequestsPerTx = FlowYieldVaultsEVM.getMaxRequestsPerTx()

    let executionsPerHourAt3s = 1200   // High load: >10 pending
    let executionsPerHourAt30s = 120   // Idle: 0 pending

    let throughput: {String: Int} = {
        "atHighLoad": maxRequestsPerTx * executionsPerHourAt3s,
        "atIdle": maxRequestsPerTx * executionsPerHourAt30s
    }

    let gasEstimate: {String: String} = {
        "description": "Varies based on request complexity",
        "rangePerRequest": "~100k-500k gas",
        "totalRange": calculateGasRange(maxRequestsPerTx)
    }

    return {
        "currentMaxRequestsPerTx": maxRequestsPerTx,
        "maxThroughputPerHour": throughput,
        "estimatedGasPerExecution": gasEstimate,
        "recommendations": getRecommendations(maxRequestsPerTx)
    }
}

access(all) fun calculateGasRange(_ batchSize: Int): String {
    let lowGas = batchSize * 100_000
    let highGas = batchSize * 500_000
    return "\(lowGas) - \(highGas) gas"
}

access(all) fun getRecommendations(_ current: Int): [String] {
    let recommendations: [String] = []

    if current < 5 {
        recommendations.append("Very small batch size - consider increasing for efficiency")
    } else if current < 10 {
        recommendations.append("Conservative batch size - good for testing")
    } else if current <= 30 {
        recommendations.append("Optimal batch size range")
    } else if current <= 50 {
        recommendations.append("Large batch size - monitor for gas issues")
    } else {
        recommendations.append("Very large batch size - high risk of gas limits")
    }

    return recommendations
}
