import Foundation

/// 初篩只找出可連線的候選；兩段不同位置的 Range 都通過才算完成吞吐驗證。
enum CDNStartupSelection {
    struct Sample {
        let url: String
        let mbps: Double
        var contentLength: Int? = nil
    }

    struct Selection {
        let sample: Sample
        let isVerified: Bool
    }

    typealias Probe = (_ url: String, _ bytes: Int, _ offset: Int, _ timeout: TimeInterval) async -> Sample?

    static func select(urls: [String], requiredMbps: Double, cachedHost: String? = nil,
                       budget: TimeInterval = 8,
                       samplingPositions: () -> (Double, Double) = { (.random(in: 0...1), .random(in: 0...1)) },
                       probe: @escaping Probe) async -> Selection?
    {
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        // 同次選點共用位置，讓候選公平比較；下次重新抽樣，避免探測本身暖出固定快取。
        let positions = samplingPositions()
        var rejected = Set<String>()
        var verified = [Sample]()

        func remaining() -> TimeInterval { max(0, deadline - ProcessInfo.processInfo.systemUptime) }

        func verify(_ header: Sample) async -> Sample? {
            guard let ranges = verificationRanges(contentLength: header.contentLength, requiredMbps: requiredMbps, positions: positions) else { return nil }
            var slowest = Double.infinity
            for (bytes, offset) in ranges {
                guard !Task.isCancelled, remaining() > 0.1,
                      let sample = await probe(header.url, bytes, offset, min(2.5, remaining())),
                      sample.contentLength == header.contentLength,
                      !Task.isCancelled
                else { return nil }
                slowest = min(slowest, sample.mbps)
            }
            return Sample(url: header.url, mbps: slowest, contentLength: header.contentLength)
        }

        // 快取只提供優先驗證順序；本片的長度仍須由本次 header 取得。
        let cachedURL = cachedHost.flatMap { host in urls.first { URLComponents(string: $0)?.host == host } }
        var cachedSample: Sample?
        if let cachedURL, !Task.isCancelled, remaining() > 0.1 {
            cachedSample = await probe(cachedURL, 64 * 1024, 0, min(0.75, remaining()))
            guard !Task.isCancelled else { return nil }
            if let header = cachedSample,
               remaining() > 0.1,
               verificationRanges(contentLength: header.contentLength, requiredMbps: requiredMbps, positions: positions) != nil
            {
                rejected.insert(cachedURL)
                if let sample = await verify(header) {
                    if sample.mbps >= requiredMbps { return Selection(sample: sample, isVerified: true) }
                    verified.append(sample)
                }
            }
        }
        guard !Task.isCancelled else { return nil }

        let candidates = urls.filter { $0 != cachedURL }
        let screeningDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 1.5)
        let screened = await withTaskGroup(of: Sample?.self, returning: [Sample].self) { group in
            var next = 0
            func enqueue() {
                guard next < candidates.count else { return }
                let time = screeningDeadline - ProcessInfo.processInfo.systemUptime
                guard time > 0.1, !Task.isCancelled else { return }
                let url = candidates[next]
                next += 1
                group.addTask { await probe(url, 64 * 1024, 0, min(0.75, time)) }
            }
            // 大量自訂節點時也不會同時搶占所有頻寬。
            for _ in 0..<6 {
                enqueue()
            }
            var samples = [Sample]()
            for await sample in group {
                if let sample { samples.append(sample) }
                enqueue()
            }
            return samples.sorted { $0.mbps > $1.mbps }
        }

        // 未知長度不可盲目請求後段，也不應佔用可驗證候選的名額。
        let verifiable = screened.filter { verificationRanges(contentLength: $0.contentLength, requiredMbps: requiredMbps, positions: positions) != nil }
        for candidate in verifiable.prefix(3) {
            guard !Task.isCancelled, remaining() > 0.1 else { break }
            rejected.insert(candidate.url)
            if let sample = await verify(candidate) {
                verified.append(sample)
                // 已達含餘裕的需求即起播，無須等所有節點測完。
                if sample.mbps >= requiredMbps { return Selection(sample: sample, isVerified: true) }
            }
        }
        guard !Task.isCancelled else { return nil }
        if let best = verified.max(by: { $0.mbps < $1.mbps }) {
            return Selection(sample: best, isVerified: true)
        }
        // 預算用盡時只回退尚未被大樣本判定失敗的可用候選，且不寫入健康快取。
        let fallback = (screened + [cachedSample].compactMap { $0 }).sorted { $0.mbps > $1.mbps }
        return fallback.first(where: { !rejected.contains($0.url) }).map { Selection(sample: $0, isVerified: false) }
    }

    private static func verificationRanges(contentLength: Int?, requiredMbps: Double,
                                           positions: (Double, Double)) -> [(bytes: Int, offset: Int)]?
    {
        guard let contentLength, contentLength >= 3 else { return nil }
        // 取約兩秒需求量，避免短暫突發頻寬掩蓋持續吞吐不足；低碼率仍可縮小樣本。
        let targetBytes = Int(min(Double(8 * 1024 * 1024), max(Double(512 * 1024), requiredMbps * 125_000 * 2)))
        // 完整樣本分別落在前中段15%～45%、後段55%～85%；短片縮小樣本，
        // 極短檔案則把整數邊界調成至少各有1 byte，仍不得重疊或超出檔尾。
        let firstStart = max(1, Int(Double(contentLength) * 0.15))
        let firstEnd = max(firstStart + 1, Int(Double(contentLength) * 0.45))
        let secondStart = max(firstEnd, Int(Double(contentLength) * 0.55))
        let secondEnd = min(contentLength, max(secondStart + 1, Int(Double(contentLength) * 0.85)))
        let bytes = min(targetBytes, firstEnd - firstStart, secondEnd - secondStart)

        func offset(start: Int, end: Int, position: Double) -> Int {
            let fraction = position.isFinite ? min(1, max(0, position)) : 0.5
            let available = end - start - bytes
            return start + min(available, Int(Double(available) * fraction))
        }
        let firstOffset = offset(start: firstStart, end: firstEnd, position: positions.0)
        let secondOffset = offset(start: secondStart, end: secondEnd, position: positions.1)
        return [(bytes, firstOffset), (bytes, secondOffset)]
    }
}
