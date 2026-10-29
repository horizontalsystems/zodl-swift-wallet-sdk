//
//  SDKSynchronizer+StaticPing.swift
//
//  HS delta on top of upstream 2.7.0-rc.2: lightwalletd reachability/latency probing without a
//  Synchronizer instance, for auto-select flows that run before any wallet/synchronizer exists.
//  Raw metrics only — filtering/selection policy lives in the app. Direct gRPC by choice, not
//  impossibility (Tor bootstrap per probe is slow and nothing owns a torDir yet); Tor-aware
//  ranking must use the instance `evaluateBestOf` instead.

import Foundation
import libzcashlc

extension SDKSynchronizer {
    public struct EndpointPingResult: Sendable {
        public let endpoint: LightWalletEndpoint
        /// Mean of the two calls (`getInfo` + `getLatestBlockHeight`), seconds; the score
        /// `evaluateBestOf` prefilters top-k by (its final ranking is block-stream throughput).
        public let responseTime: TimeInterval
        /// Latest best-chain block, from the same `getInfo` sample as `estimatedHeight` —
        /// compare the two within this sample (see `ZcashSDK.syncedThresholdBlocks`).
        public let blockHeight: BlockHeight
        /// Self-reported estimate; above `blockHeight` while the server is syncing, and may be
        /// quite inaccurate — treat any threshold against it as a loose check.
        public let estimatedHeight: BlockHeight
        /// "main" or "test".
        public let chainName: String
        public let saplingActivationHeight: BlockHeight
        /// Protocol identifier, see consensus/upgrades.cpp. Informational; normalize with
        /// `ConsensusBranchID.fromString(_:)` before comparing values across servers.
        public let consensusBranchID: String
    }

    /// Consensus branch the local rules expect at `height`, for comparing against
    /// `EndpointPingResult.consensusBranchID` (as `evaluateBestOf` does); nil if unknown.
    public static func consensusBranchID(at height: BlockHeight, networkType: NetworkType) -> ConsensusBranchID? {
        let branchID = zcashlc_branch_id_for_height(Int32(clamping: height), networkType.networkId)
        return branchID == -1 ? nil : branchID
    }

    /// Parallel probe; failing endpoints are omitted, results arrive in completion order.
    /// `timeout` is a hard per-endpoint deadline covering both calls, so the group is bounded.
    public static func pingEndpoints(_ endpoints: [LightWalletEndpoint], timeout: TimeInterval = 5) async -> [EndpointPingResult] {
        // clamp: a public Double parameter must not trap the nanosecond conversion
        let timeout = min(max(timeout, 0.1), 3600)

        return await withTaskGroup(of: EndpointPingResult?.self) { group in
            for endpoint in endpoints {
                group.addTask { await ping(endpoint: endpoint, timeout: timeout) }
            }

            var results: [EndpointPingResult] = []
            for await result in group {
                if let result {
                    results.append(result)
                }
            }
            return results
        }
    }

    // Deadline race: the in-band gRPC deadline bounds the calls, this additionally bounds
    // connect-retry spins (unlimited in gRPC) so a tarpitting host cannot stall the batch.
    private static func ping(endpoint: LightWalletEndpoint, timeout: TimeInterval) async -> EndpointPingResult? {
        await withTaskGroup(of: EndpointPingResult?.self) { group in
            group.addTask { await measure(endpoint: endpoint, timeout: timeout) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }

            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }
    }

    private static func measure(endpoint: LightWalletEndpoint, timeout: TimeInterval) async -> EndpointPingResult? {
        // In-band gRPC deadline (endpoint default is 30s/call, too slow for a probe): if task
        // cancellation ever regresses in grpc-swift, the probe degrades to slow, not hanging.
        let service = LightWalletGRPCService(
            host: endpoint.host,
            port: endpoint.port,
            secure: endpoint.secure,
            singleCallTimeout: Int64(timeout * 1000),
            streamingCallTimeout: Int64(timeout * 1000)
        )
        defer { service.stop() }

        // Monotonic clock: a wall-clock Date() sample would be corrupted if NTP steps the clock.
        let start = DispatchTime.now()
        guard let info = try? await service.getInfo(mode: .direct) else { return nil }
        let mark = DispatchTime.now()
        // The value is deliberately unused: heights come from the single `info` sample above so
        // they are mutually coherent; this call contributes reachability proof and latency only.
        guard (try? await service.latestBlockHeight(mode: .direct)) != nil else { return nil }
        let end = DispatchTime.now()

        let getInfoTime = Double(mark.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        let latestHeightTime = Double(end.uptimeNanoseconds - mark.uptimeNanoseconds) / 1_000_000_000

        // Clamping: heights come from an untrusted server; a bogus UInt64 must not trap the probe.
        return EndpointPingResult(
            endpoint: endpoint,
            responseTime: (getInfoTime + latestHeightTime) / 2,
            blockHeight: BlockHeight(clamping: info.blockHeight),
            estimatedHeight: BlockHeight(clamping: info.estimatedHeight),
            chainName: info.chainName,
            saplingActivationHeight: BlockHeight(clamping: info.saplingActivationHeight),
            consensusBranchID: info.consensusBranchID
        )
    }
}
