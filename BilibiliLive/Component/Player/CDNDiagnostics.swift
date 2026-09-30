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
        var contentLength: Int? = nil

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

        /// 小樣本也計入連線與首位元組等待，避免高延遲節點的瞬間傳輸速率過度樂觀。
        var effectiveMbps: Double? {
            let elapsed = setupTime + transferTime
            guard error == nil, elapsed > 0, bytes > 0 else { return nil }
            return Double(bytes) * 8 / elapsed / 1_000_000
        }
    }

    /// 選單手動完整測速使用較大樣本，結果更穩
    private static let fullProbeBytes = 2 * 1024 * 1024
    /// 只短暫保留已驗證的吞吐；下一部影片仍會重新驗證候選。
    private actor QuickProbeCache {
        private var host: String?
        private var mbps: Double = 0
        private var updatedAt = Date.distantPast
        private var generation = 0

        func cachedHost(in urls: [String], requiredMbps: Double) -> String? {
            guard Date().timeIntervalSince(updatedAt) < 60, mbps >= requiredMbps,
                  let host, urls.contains(where: { URLComponents(string: $0)?.host == host })
            else { return nil }
            return host
        }

        func revision() -> Int { generation }

        func store(host: String, mbps: Double, revision: Int) {
            guard revision == generation else { return }
            self.host = host
            self.mbps = mbps
            updatedAt = Date()
        }

        func invalidate(host: String) {
            generation += 1
            if self.host == host { self.host = nil }
        }
    }

    private static let quickProbeCache = QuickProbeCache()

    static func invalidate(host: String) async {
        await quickProbeCache.invalidate(host: host)
    }

    /// 背景暖機只能使用近期已通過驗證的節點，不在播放時額外啟動吞吐測速。
    static func cachedHost(urls: [String], requiredMbps: Double) async -> String? {
        await quickProbeCache.cachedHost(in: urls, requiredMbps: requiredMbps)
    }

    private static let session: Session = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.headers = HTTPHeaders(["User-Agent": Keys.userAgent])
        return Session(configuration: config)
    }()

    private static let quickSession: Session = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.headers = HTTPHeaders(["User-Agent": Keys.userAgent])
        return Session(configuration: config)
    }()

    /// 逐個實測所有候選，供手動完整測速報告使用。
    /// 顺序测而非并发：并发会让候选互相抢带宽导致结果失真。
    static func probeAll(urls: [String]) async -> [ProbeResult] {
        await probeAll(urls: urls, bytes: fullProbeBytes, session: session)
    }

    /// 播放中避免完整测速搶占頻寬：最多試三個備援，足夠快就立即返回。
    /// 若備援均不足，才測目前節點供呼叫端比較，避免盲目切到更慢的來源。
    static func probeForRecovery(urls: [String], currentHost: String, requiredMbps: Double) async -> [ProbeResult] {
        var results = [ProbeResult]()
        let alternatives = urls.filter { URLComponents(string: $0)?.host != currentHost }
        for url in alternatives.prefix(3) {
            guard !Task.isCancelled else { return results }
            let result = await probe(url: url, bytes: 256 * 1024, session: quickSession)
            results.append(result)
            if requiredMbps > 0, let speed = result.effectiveMbps, speed >= requiredMbps {
                return results
            }
        }
        if !Task.isCancelled, let current = urls.first(where: { URLComponents(string: $0)?.host == currentHost }) {
            results.append(await probe(url: current, bytes: 256 * 1024, session: quickSession))
        }
        return results
    }

    /// 起播採兩階段驗證，包含快取重驗在內最多約八秒。
    static func pickFastestHost(urls: [String], requiredMbps: Double = 0) async -> String? {
        guard !urls.isEmpty, !Task.isCancelled else { return nil }
        let cached = await cachedHost(urls: urls, requiredMbps: requiredMbps)
        // 重驗失敗時不能讓舊的健康判定繼續供背景暖機使用。
        if let cached { await quickProbeCache.invalidate(host: cached) }
        let revision = await quickProbeCache.revision()
        let selection = await CDNStartupSelection.select(urls: urls, requiredMbps: requiredMbps, cachedHost: cached) { url, bytes, offset, timeout in
            let result = await probe(url: url, bytes: bytes, session: quickSession, offset: offset, timeout: timeout)
            guard let speed = result.effectiveMbps else { return nil }
            Logger.info("[cdn] 起播取樣 \(result.host) \(result.bytes / 1024)KB @\(offset): \(String(format: "%.1f", speed))Mbps")
            return CDNStartupSelection.Sample(url: url, mbps: speed, contentLength: result.contentLength)
        }
        guard !Task.isCancelled, let selection,
              let host = URLComponents(string: selection.sample.url)?.host
        else { return nil }
        if selection.isVerified, selection.sample.mbps >= requiredMbps {
            await quickProbeCache.store(host: host, mbps: selection.sample.mbps, revision: revision)
        }
        Logger.info("[cdn] 起播選用 \(host), 驗證=\(selection.isVerified), 需求 \(String(format: "%.1f", requiredMbps))Mbps")
        return host
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

    private static func probe(url: String, bytes: Int, session: Session, offset: Int = 0,
                              timeout: TimeInterval? = nil) async -> ProbeResult
    {
        let request = session.request(url, headers: [
            "Range": "bytes=\(offset)-\(offset + bytes - 1)",
            "Referer": Keys.referer,
        ]).validate(statusCode: [206])
        // request timeout 只管閒置時間；獨立期限確保持續慢速傳輸也不能拖長起播。
        let deadlineTask = timeout.map { timeout in
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                request.cancel()
            }
        }
        defer { deadlineTask?.cancel() }
        let response = await request.serializingData(automaticallyCancelling: true).response

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
            let contentLength = validatedContentLength(
                range: response.response?.value(forHTTPHeaderField: "Content-Range"),
                offset: offset, requestedBytes: bytes, receivedBytes: data.count
            )
            if timeout != nil {
                guard contentLength != nil else {
                    return ProbeResult(url: url, bytes: 0, transferTime: transferTime,
                                       setupTime: setupTime, error: "不完整的 Range 回應")
                }
            }
            return ProbeResult(url: url, bytes: data.count,
                               transferTime: transferTime, setupTime: setupTime, error: nil,
                               contentLength: contentLength)
        case let .failure(error):
            return ProbeResult(url: url, bytes: 0,
                               transferTime: transferTime, setupTime: setupTime,
                               error: error.localizedDescription)
        }
    }

    /// 接受伺服器在 EOF 合法縮短 Range，但拒絕錯誤起點、缺資料或不一致的總長。
    private static func validatedContentLength(range: String?, offset: Int,
                                               requestedBytes: Int, receivedBytes: Int) -> Int?
    {
        guard let range = range?.lowercased(), range.hasPrefix("bytes "),
              offset >= 0, requestedBytes > 0, receivedBytes > 0
        else { return nil }
        let parts = range.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int(parts[1]), total > offset else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]),
              start == offset, end >= start, end < total,
              end - start + 1 == receivedBytes,
              receivedBytes == min(requestedBytes, total - offset)
        else { return nil }
        return total
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
