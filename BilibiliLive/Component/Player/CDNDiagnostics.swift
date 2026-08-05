//
//  CDNDiagnostics.swift
//  BilibiliLive
//

import Alamofire
import Foundation

/// 主动实测各 CDN 候选节点的吞吐。
///
/// 用固定大小的 Range 请求实测各 CDN 候选吞吐。
/// 静态域名分级已不再承担选速职责（仅 PCDN 垫底），起播 sidx 也只验证连通性。
enum CDNDiagnostics {
    struct ProbeResult {
        let url: String
        let bytes: Int
        /// 首字节之后的传输耗时，反映纯下载速度
        let transferTime: TimeInterval
        /// DNS + 建连 + TLS + 首字节等待，跨境链路的高 RTT 主要体现在这里
        let setupTime: TimeInterval
        let error: String?

        var host: String {
            URLComponents(string: url)?.host ?? "unknown"
        }

        var isPCDN: Bool {
            BVideoUrlUtils.isPCDN(url)
        }

        var mbps: Double? {
            guard error == nil, transferTime > 0, bytes > 0 else { return nil }
            return Double(bytes) * 8 / transferTime / 1_000_000
        }
    }

    /// 菜单手动测速 / 运行时切换：较大样本，结果更稳
    private static let fullProbeBytes = 2 * 1024 * 1024
    /// 起播择优只需要快速分辨可用性与相对速度。所有候选会并行请求，因此保持小样本，
    /// 避免节点很多时同时下载过多数据、反而让候选互相抢带宽。
    private static let quickProbeBytes = 64 * 1024
    /// 短时间内连续播放时沿用上次胜出的节点，避免每部影片都重新等待测速。
    private static let quickProbeCacheLifetime: TimeInterval = 5 * 60

    private actor QuickProbeCache {
        private var host: String?
        private var updatedAt = Date.distantPast

        func cachedHost(in urls: [String], lifetime: TimeInterval) -> String? {
            guard Date().timeIntervalSince(updatedAt) < lifetime,
                  let host,
                  urls.contains(where: { URLComponents(string: $0)?.host == host })
            else {
                host = nil
                return nil
            }
            return host
        }

        func store(host: String) {
            self.host = host
            updatedAt = Date()
        }
    }

    private static let quickProbeCache = QuickProbeCache()

    private static let session: Session = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.headers = HTTPHeaders(["User-Agent": Keys.userAgent])
        return Session(configuration: config)
    }()

    private static let quickSession: Session = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.headers = HTTPHeaders(["User-Agent": Keys.userAgent])
        return Session(configuration: config)
    }()

    /// 逐个实测所有候选，返回原始结果供调用方自行判断（如运行时健康检测比较吞吐）。
    /// 顺序测而非并发：并发会让候选互相抢带宽导致结果失真。
    static func probeAll(urls: [String]) async -> [ProbeResult] {
        await probeAll(urls: urls, bytes: fullProbeBytes, session: session)
    }

    /// 起播用轻量测速，选出实测最快的 host；候选不足或全部失败时返回 nil。
    static func pickFastestHost(urls: [String]) async -> String? {
        guard urls.count > 1 else {
            return urls.first.flatMap { URLComponents(string: $0)?.host }
        }
        if let cachedHost = await quickProbeCache.cachedHost(in: urls, lifetime: quickProbeCacheLifetime) {
            Logger.info("[cdn] 起播沿用最近测速 host: \(cachedHost)")
            return cachedHost
        }

        // 起播测速与菜单里的完整测速目标不同：这里优先限制播放前的总等待时间。
        // 一次并行启动所有短请求，使最坏等待接近单个请求的超时，而不是「节点数 × 超时」。
        let results = await probeConcurrently(urls: urls, bytes: quickProbeBytes, session: quickSession)
        let ranked = results.sorted { ($0.mbps ?? -1) > ($1.mbps ?? -1) }
        let summary = ranked.map { r in
            let speed = r.mbps.map { String(format: "%.1fMbps", $0) } ?? "失败"
            return "\(r.host)=\(speed)"
        }.joined(separator: ", ")
        Logger.info("[cdn] 起播并行轻量测速 (\(quickProbeBytes / 1024)KB): \(summary)")
        let fastestHost = ranked.first(where: { $0.mbps != nil })?.host
        if let fastestHost {
            await quickProbeCache.store(host: fastestHost)
        }
        return fastestHost
    }

    /// 测速并把结果写进日志，返回适合直接显示的文本。
    static func run(urls: [String], currentHost: String?) async -> String {
        guard !urls.isEmpty else { return "无候选 CDN" }
        let results = await probeAll(urls: urls)
        let text = report(results, currentHost: currentHost, probeBytes: fullProbeBytes)
        Logger.info("\n\(text)")
        return text
    }

    private static func probeAll(urls: [String], bytes: Int, session: Session) async -> [ProbeResult] {
        var results = [ProbeResult]()
        for url in urls {
            results.append(await probe(url: url, bytes: bytes, session: session))
        }
        return results
    }

    private static func probeConcurrently(urls: [String], bytes: Int, session: Session) async -> [ProbeResult] {
        await withTaskGroup(of: ProbeResult.self, returning: [ProbeResult].self) { group in
            for url in urls {
                group.addTask {
                    await probe(url: url, bytes: bytes, session: session)
                }
            }

            var results = [ProbeResult]()
            results.reserveCapacity(urls.count)
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    private static func probe(url: String, bytes: Int, session: Session) async -> ProbeResult {
        let response = await session.request(url, headers: [
            "Range": "bytes=0-\(bytes - 1)",
            "Referer": Keys.referer,
        ]).serializingData().response

        var setupTime: TimeInterval = 0
        var transferTime = response.metrics?.taskInterval.duration ?? 0
        if let metrics = response.metrics?.transactionMetrics.last,
           let fetchStart = metrics.fetchStartDate,
           let responseStart = metrics.responseStartDate,
           let responseEnd = metrics.responseEndDate
        {
            setupTime = responseStart.timeIntervalSince(fetchStart)
            transferTime = responseEnd.timeIntervalSince(responseStart)
        }

        switch response.result {
        case let .success(data):
            return ProbeResult(url: url, bytes: data.count,
                               transferTime: transferTime, setupTime: setupTime, error: nil)
        case let .failure(error):
            return ProbeResult(url: url, bytes: 0,
                               transferTime: transferTime, setupTime: setupTime,
                               error: error.localizedDescription)
        }
    }

    private static func report(_ results: [ProbeResult], currentHost: String?, probeBytes: Int) -> String {
        let ranked = results.sorted { ($0.mbps ?? -1) > ($1.mbps ?? -1) }
        var lines = ["CDN 实测 (\(probeBytes / 1024)KB/节点, 按实测速度排序)"]
        for (index, result) in ranked.enumerated() {
            let speed = result.mbps.map { String(format: "%.1f Mbps", $0) } ?? "失败"
            let setup = String(format: "%.0fms", result.setupTime * 1000)
            var line = "\(index + 1). \(speed)  setup \(setup)  \(result.host)"
            if result.isPCDN {
                line += "  PCDN"
            }
            if result.host == currentHost {
                line += "  <- 正在使用"
            }
            if let error = result.error {
                line += "  (\(error))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
