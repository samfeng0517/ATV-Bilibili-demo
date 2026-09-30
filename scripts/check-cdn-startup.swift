import Foundation

// 由 check-cdn-startup.sh 與正式 CDNStartupSelection.swift 一起編譯，完全不存取外網。
private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

private actor SimulatedCDN {
    struct Reply {
        let mbps: Double?
        var delay: TimeInterval = 0
        var honorsCancellation = true
        var contentLengthOverride: Int?
    }

    struct Plan {
        let header: Reply
        let first: Reply
        let second: Reply
        var contentLength: Int? = 192 * 1024 * 1024
    }

    struct Call {
        let url: String
        let bytes: Int
        let offset: Int
        let timeout: TimeInterval
    }

    struct Snapshot {
        let calls: [Call]
        let maximumConcurrency: Int
        let active: Int
    }

    private let plans: [String: Plan]
    private let defaultPlan: Plan
    private var calls = [Call]()
    private var validationCounts = [String: Int]()
    private var active = 0
    private var maximumConcurrency = 0
    private var waiters = [(count: Int, continuation: CheckedContinuation<Void, Never>)]()

    init(plans: [String: Plan] = [:], defaultPlan: Plan = Plan(
        header: Reply(mbps: nil), first: Reply(mbps: nil), second: Reply(mbps: nil)
    )) {
        self.plans = plans
        self.defaultPlan = defaultPlan
    }

    func probe(url: String, bytes: Int, offset: Int, timeout: TimeInterval) async -> CDNStartupSelection.Sample? {
        let plan = plans[url] ?? defaultPlan
        let reply: Reply
        if offset == 0 {
            reply = plan.header
        } else {
            let index = validationCounts[url, default: 0]
            validationCounts[url] = index + 1
            reply = index == 0 ? plan.first : plan.second
        }
        calls.append(Call(url: url, bytes: bytes, offset: offset, timeout: timeout))
        active += 1
        maximumConcurrency = max(maximumConcurrency, active)
        defer { active -= 1 }
        let ready = waiters.filter { calls.count >= $0.count }
        waiters.removeAll { calls.count >= $0.count }
        ready.forEach { $0.continuation.resume() }

        // 模擬實際 probe 的逾時取消；若取消時回應已送達，可特別模擬成功回應競態。
        let elapsed = min(reply.delay, max(0, timeout))
        if elapsed > 0 {
            try? await Task.sleep(nanoseconds: UInt64(elapsed * 1_000_000_000))
        }
        guard reply.delay <= timeout,
              !reply.honorsCancellation || !Task.isCancelled,
              let mbps = reply.mbps
        else { return nil }
        return CDNStartupSelection.Sample(url: url, mbps: mbps,
                                          contentLength: reply.contentLengthOverride ?? plan.contentLength)
    }

    func waitUntilCallCount(_ count: Int) async {
        if calls.count >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(calls: calls, maximumConcurrency: maximumConcurrency, active: active)
    }
}

@main
private enum CDNStartupChecks {
    private static let a = "https://a.example/video.m4s"
    private static let b = "https://b.example/video.m4s"
    private static let c = "https://c.example/video.m4s"
    private static let d = "https://d.example/video.m4s"

    private static func plan(_ header: Double?, _ first: Double?, _ second: Double?) -> SimulatedCDN.Plan {
        .init(header: .init(mbps: header), first: .init(mbps: first), second: .init(mbps: second))
    }

    private static func select(_ fixture: SimulatedCDN, urls: [String], required: Double = 10,
                               cachedHost: String? = nil, budget: TimeInterval = 8,
                               samplingPositions: (Double, Double) = (0.25, 0.75)) async -> CDNStartupSelection.Selection?
    {
        await CDNStartupSelection.select(urls: urls, requiredMbps: required, cachedHost: cachedHost, budget: budget,
                                         samplingPositions: { samplingPositions })
        {
            await fixture.probe(url: $0, bytes: $1, offset: $2, timeout: $3)
        }
    }

    private static func rejectHeaderBurstAndFailure() async throws {
        let fixture = SimulatedCDN(plans: [a: plan(100, 2, 1), b: plan(80, nil, nil), c: plan(60, 14, 13)])
        let result = await select(fixture, urls: [a, b, c])
        try expect(result?.sample.url == c, "檔頭最快但持續吞吐不足，以及大樣本失敗的節點，皆不得勝出")
        try expect(result?.isVerified == true, "勝出的節點必須通過兩段大樣本")
    }

    private static func useSlowerSample() async throws {
        let fixture = SimulatedCDN(plans: [a: plan(100, 30, 2), b: plan(50, 5, 12)])
        let result = await select(fixture, urls: [a, b])
        try expect(result?.sample.url == b, "兩段樣本須以較慢者排序，不能以平均或第一段排序")
        try expect(result?.sample.mbps == 5, "應保留較慢樣本 5 Mbps，不可只採最後一段 12 Mbps")
        try expect(result?.isVerified == true, "未達需求時仍須區分完成驗證的最佳可用節點")
    }

    private static func stopWhenSufficient() async throws {
        let fixture = SimulatedCDN(plans: [a: plan(100, 12, 11), b: plan(80, 40, 40), c: plan(60, 50, 50)])
        let result = await select(fixture, urls: [a, b, c])
        let state = await fixture.snapshot()
        try expect(result?.sample.url == a, "首個已達含餘裕需求的節點應立即勝出")
        try expect(state.calls.filter { $0.offset > 0 }.map(\.url) == [a, a], "達標後不應再對其他節點做大樣本測速")
    }

    private static func revalidateCachedHost() async throws {
        let fixture = SimulatedCDN(plans: [a: plan(1, 12, 11), b: plan(100, 50, 50)])
        let result = await select(fixture, urls: [a, b], cachedHost: "a.example")
        let calls = await fixture.snapshot().calls
        try expect(result?.sample.url == a, "仍健康的快取節點應優先重驗並使用")
        try expect(calls.count == 3 && calls.allSatisfy { $0.url == a }, "快取命中也須取得本片長度並完成兩次非檔頭驗證")
        try expect(calls[0].offset == 0 && calls[0].bytes == 64 * 1024, "快取節點必須先重新請求64KB檔頭取得本片長度")
        try expect(calls[1].bytes == 2_500_000 && calls[2].bytes == 2_500_000, "10Mbps需求應取約兩秒資料量")
        let length = 192 * 1024 * 1024
        try expect(calls[1].offset >= Int(Double(length) * 0.15) &&
            calls[1].offset + calls[1].bytes <= Int(Double(length) * 0.45) &&
            calls[2].offset >= Int(Double(length) * 0.55) &&
            calls[2].offset + calls[2].bytes <= Int(Double(length) * 0.85),
            "快取節點也須在前中與後段分區取得完整樣本，不可只測檔頭熱快取")
        try expect(calls.dropFirst().allSatisfy { $0.timeout <= 2.5 }, "每段驗證最多2.5秒")
    }

    private static func rejectFailedCachedHost() async throws {
        let fixture = SimulatedCDN(plans: [a: plan(100, nil, nil), b: plan(50, 20, 19)])
        let result = await select(fixture, urls: [a, b], cachedHost: "a.example")
        let calls = await fixture.snapshot().calls
        try expect(result?.sample.url == b, "快取節點重驗失敗時應改選其他節點")
        try expect(calls.filter { $0.url == a }.count == 2, "快取節點取得檔頭後驗證失敗，不應又透過初篩被沿用")
    }

    private static func respectOverallBudget() async throws {
        let slow = SimulatedCDN.Reply(mbps: 100, delay: 3)
        let fixture = SimulatedCDN(defaultPlan: .init(header: slow, first: slow, second: slow))
        let urls = (0..<18).map { "https://slow\($0).example/video.m4s" }
        let budget = 0.35
        let started = ProcessInfo.processInfo.systemUptime
        let result = await select(fixture, urls: urls, budget: budget)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let state = await fixture.snapshot()
        try expect(result == nil, "所有節點都逾時時不可產生成功選點")
        try expect(elapsed <= budget + 0.2, "總預算 \(budget)s 被突破，耗時 \(elapsed)s")
        try expect(state.calls.count == 6, "預算用盡後不可繼續啟動後續批次")
        try expect(state.calls.allSatisfy { $0.timeout <= budget }, "各探測必須繼承剩餘總預算")
        try expect(state.active == 0, "返回後不可留下進行中的探測")
    }

    private static func cancelDuringScreening() async throws {
        let slow = SimulatedCDN.Reply(mbps: 100, delay: 3)
        let fixture = SimulatedCDN(defaultPlan: .init(header: slow, first: slow, second: slow))
        let task = Task { await select(fixture, urls: [a, b, c]) }
        await fixture.waitUntilCallCount(1)
        task.cancel()
        let result = await task.value
        let state = await fixture.snapshot()
        try expect(result == nil, "初篩期間取消後不可回傳節點")
        try expect(state.active == 0, "取消完成後不可留下進行中的探測")
    }

    private static func cancelAtFinalSample() async throws {
        let finalResponse = SimulatedCDN.Reply(mbps: 20, delay: 0.5, honorsCancellation: false)
        let fixture = SimulatedCDN(plans: [a: .init(header: .init(mbps: 100), first: .init(mbps: 20), second: finalResponse)])
        let task = Task { await select(fixture, urls: [a], cachedHost: "a.example") }
        await fixture.waitUntilCallCount(3)
        task.cancel()
        let result = await task.value
        try expect(result == nil, "最後一段回應與取消同時完成時，也不可回傳已取消的選點")
    }

    private static func keepScreenedFallbackUnverified() async throws {
        let fixture = SimulatedCDN(plans: [a: plan(100, nil, nil), b: plan(80, nil, nil),
                                           c: plan(60, nil, nil), d: plan(40, 50, 50)])
        let result = await select(fixture, urls: [a, b, c, d])
        let calls = await fixture.snapshot().calls
        try expect(result?.sample.url == d, "應回退至尚未被大樣本判定失敗的候選")
        try expect(result?.isVerified == false, "僅完成初篩的回退不可標示為已驗證")
        try expect(!calls.contains { $0.url == d && $0.offset > 0 }, "此案例必須確實僅初篩回退")
    }

    private static func keepBudgetFallbackUnverified() async throws {
        let fixture = SimulatedCDN(plans: [a: .init(header: .init(mbps: 50, delay: 0.12),
                                                    first: .init(mbps: 50), second: .init(mbps: 50))])
        let result = await select(fixture, urls: [a], budget: 0.15)
        let calls = await fixture.snapshot().calls
        try expect(result?.sample.url == a && result?.isVerified == false, "初篩後預算不足時只能回傳未驗證回退")
        try expect(calls.count == 1 && calls[0].offset == 0, "預算不足不應啟動大樣本")
    }

    private static func fitSamplesInsideShortFiles() async throws {
        for length in [3, 4, 5, 6, 31 * 1024, 64 * 1024, 1024 * 1024, 8 * 1024 * 1024, 24 * 1024 * 1024, Int.max] {
            var replies = plan(100, 20, 19)
            replies.contentLength = length
            let fixture = SimulatedCDN(plans: [a: replies])
            let result = await select(fixture, urls: [a])
            let samples = await fixture.snapshot().calls.filter { $0.offset > 0 }
            try expect(result?.isVerified == true && samples.count == 2, "短檔案 \(length) bytes 仍應完成兩次有效取樣")
            try expect(samples.allSatisfy { $0.bytes > 0 && $0.offset + $0.bytes <= length },
                       "短檔案 \(length) bytes 的 Range 不可超出檔尾或請求0 bytes")
            try expect(samples[0].offset + samples[0].bytes <= samples[1].offset,
                       "短檔案 \(length) bytes 不可重複取樣同一尾段")
        }
    }

    private static func varyPositionsAcrossSelections() async throws {
        // 注入分區兩端，明確驗證抽樣值會影響位置，不依賴真亂數碰巧不同。
        for length in [192 * 1024 * 1024, 768 * 1024 * 1024] {
            var offsets = [[Int]]()
            for positions: (Double, Double) in [(0, 0), (1, 1)] {
                var replies = plan(100, 20, 19)
                replies.contentLength = length
                let fixture = SimulatedCDN(plans: [a: replies])
                _ = await select(fixture, urls: [a], samplingPositions: positions)
                let samples = await fixture.snapshot().calls.filter { $0.offset > 0 }
                try expect(samples.count == 2, "每次選點仍只需要兩段吞吐驗證")
                try expect(samples[0].offset >= Int(Double(length) * 0.15) &&
                    samples[0].offset + samples[0].bytes <= Int(Double(length) * 0.45),
                    "第一段完整Range應位於全片15%～45%，包含抽樣分區端點")
                try expect(samples[1].offset >= Int(Double(length) * 0.55) &&
                    samples[1].offset + samples[1].bytes <= Int(Double(length) * 0.85),
                    "第二段完整Range應位於全片55%～85%，包含抽樣分區端點")
                offsets.append(samples.map(\.offset))
            }
            try expect(offsets[0][0] != offsets[1][0] && offsets[0][1] != offsets[1][1],
                       "下一次選點抽到不同值時，两段都應換位置，避免固定片段被自己暖快取")
        }
    }

    private static func sharePositionsAcrossCandidates() async throws {
        let fixture = SimulatedCDN(plans: [a: plan(100, 9, 8), b: plan(80, 20, 19)])
        var sourceCalls = 0
        let result = await CDNStartupSelection.select(urls: [a, b], requiredMbps: 10, cachedHost: "a.example",
                                                      samplingPositions: {
                                                          sourceCalls += 1
                                                          return (0.2, 0.8)
                                                      }) {
            await fixture.probe(url: $0, bytes: $1, offset: $2, timeout: $3)
        }
        let samples = await fixture.snapshot().calls.filter { $0.offset > 0 }
        let first = samples.filter { $0.url == a }
        let second = samples.filter { $0.url == b }
        try expect(result?.sample.url == b && sourceCalls == 1, "每次select只可抽一組位置，快取驗證也共用")
        try expect(first.count == 2 && second.count == 2 && first.map(\.offset) == second.map(\.offset) &&
            first.map(\.bytes) == second.map(\.bytes), "同檔案各候選必須比較相同位置與相同樣本長度")
    }

    private static func adaptSampleSizeToThroughput() async throws {
        let low = SimulatedCDN(plans: [a: plan(20, 4, 3)])
        let lowResult = await select(low, urls: [a], required: 1)
        let lowSamples = await low.snapshot().calls.filter { $0.offset > 0 }
        try expect(lowResult?.isVerified == true, "低需求影片的合格節點仍可通過")
        try expect(lowSamples.count == 2 && lowSamples.allSatisfy { $0.bytes == 512 * 1024 },
                   "1Mbps需求只需512KB樣本，不可被固定4MB樣本強迫達到13Mbps")

        let medium = SimulatedCDN(plans: [a: plan(100, 30, 25)])
        _ = await select(medium, urls: [a], required: 20)
        let mediumSamples = await medium.snapshot().calls.filter { $0.offset > 0 }
        try expect(mediumSamples.count == 2 && mediumSamples.allSatisfy { $0.bytes == 5_000_000 },
                   "每段需要兩秒的需求量，不能只驗到短暫突發吞吐")

        let high = SimulatedCDN(plans: [a: plan(120, 100, 90)])
        _ = await select(high, urls: [a], required: 80)
        let highSamples = await high.snapshot().calls.filter { $0.offset > 0 }
        try expect(highSamples.count == 2 && highSamples.allSatisfy { $0.bytes == 8 * 1024 * 1024 },
                   "高需求樣本仍須限制在8MB，避免無限制流量")
    }

    private static func keepUnknownLengthUnverified() async throws {
        for length: Int? in [nil, 0, -1, 1, 2] {
            var replies = plan(100, 30, 30)
            replies.contentLength = length
            let fixture = SimulatedCDN(plans: [a: replies])
            let result = await select(fixture, urls: [a], cachedHost: "a.example")
            let calls = await fixture.snapshot().calls
            try expect(result?.sample.url == a && result?.isVerified == false,
                       "未知或無法切成兩段的長度 \(String(describing: length)) 只能未驗證回退")
            try expect(calls.count == 1 && calls[0].offset == 0, "未知或過短檔案不可盲目請求後段，也不可重測快取檔頭")
        }
    }

    private static func prioritizeKnownLengthCandidates() async throws {
        var unknown = plan(100, 30, 30)
        unknown.contentLength = nil
        let fixture = SimulatedCDN(plans: [a: unknown, b: unknown, c: unknown, d: plan(40, 20, 19)])
        let result = await select(fixture, urls: [a, b, c, d])
        let samples = await fixture.snapshot().calls.filter { $0.offset > 0 }
        try expect(result?.sample.url == d && result?.isVerified == true, "未知長度候選不應佔用三個可驗證名額")
        try expect(samples.count == 2 && samples.allSatisfy { $0.url == d }, "只能對已知長度的URL請求後段")
    }

    private static func rejectChangingContentLength() async throws {
        let changed = SimulatedCDN.Plan(header: .init(mbps: 100),
                                        first: .init(mbps: 50, contentLengthOverride: 100 * 1024 * 1024),
                                        second: .init(mbps: 50))
        let fixture = SimulatedCDN(plans: [a: changed, b: plan(80, 20, 19)])
        let result = await select(fixture, urls: [a, b])
        try expect(result?.sample.url == b, "後段總長與檔頭不一致時不可視為同一檔案的有效驗證")
    }

    private static func respectBudgetAfterCachedHeader() async throws {
        let fixture = SimulatedCDN(plans: [a: .init(header: .init(mbps: 50, delay: 0.12),
                                                    first: .init(mbps: 50), second: .init(mbps: 50))])
        let result = await select(fixture, urls: [a], cachedHost: "a.example", budget: 0.15)
        let calls = await fixture.snapshot().calls
        try expect(result?.sample.url == a && result?.isVerified == false,
                   "快取檔頭取得後若預算不足，也必須保留未驗證回退而非假裝完成驗證")
        try expect(calls.count == 1, "快取路徑預算不足時不可啟動後段請求")
    }

    private static func respectBudgetDuringValidation() async throws {
        let fixture = SimulatedCDN(plans: [a: .init(header: .init(mbps: 50),
                                                    first: .init(mbps: 50, delay: 3), second: .init(mbps: 50))])
        let budget = 0.35
        let started = ProcessInfo.processInfo.systemUptime
        let result = await select(fixture, urls: [a], cachedHost: "a.example", budget: budget)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let state = await fixture.snapshot()
        try expect(result == nil && elapsed <= budget + 0.2, "後段取樣逾時不能超過剩餘總預算")
        try expect(state.calls.count == 2 && state.calls[1].timeout <= budget,
                   "後段逾時後不得啟動第二段，且請求必須繼承剩餘預算")
        try expect(state.active == 0, "後段逾時返回後不可留下進行中的探測")
    }

    private static func capConcurrency() async throws {
        let fixture = SimulatedCDN(defaultPlan: .init(header: .init(mbps: 20, delay: 0.02),
                                                      first: .init(mbps: nil), second: .init(mbps: nil)))
        let urls = (0..<24).map { "https://node\($0).example/video.m4s" }
        _ = await select(fixture, urls: urls)
        let state = await fixture.snapshot()
        try expect(state.maximumConcurrency == 6, "初篩應允許六個並行探測，且不得超過六個")
        try expect(state.calls.filter { $0.offset == 0 }.count == urls.count, "快速回應時後續批次也須納入初篩")
        try expect(state.active == 0, "完成後不可留下進行中的探測")
    }

    static func main() async {
        let checks: [(String, () async throws -> Void)] = [
            ("檔頭突發與大樣本失敗改選", rejectHeaderBurstAndFailure),
            ("兩段取樣採較慢值", useSlowerSample),
            ("已達需求立即停止大樣本驗證", stopWhenSufficient),
            ("快取節點重新驗證不同區段", revalidateCachedHost),
            ("快取失效不再沿用", rejectFailedCachedHost),
            ("所有節點慢仍遵守總預算", respectOverallBudget),
            ("初篩取消不回傳節點", cancelDuringScreening),
            ("最終樣本與取消競態", cancelAtFinalSample),
            ("只完成初篩的回退不算已驗證", keepScreenedFallbackUnverified),
            ("預算不足的回退不算已驗證", keepBudgetFallbackUnverified),
            ("短檔案兩段取樣完整且不重疊", fitSamplesInsideShortFiles),
            ("不同選點使用不同位置且完整落在分區", varyPositionsAcrossSelections),
            ("同次快取及其他候選共用抽樣位置", sharePositionsAcrossCandidates),
            ("依吞吐需求調整樣本並限制最大流量", adaptSampleSizeToThroughput),
            ("未知長度不盲探且不標為已驗證", keepUnknownLengthUnverified),
            ("未知長度不佔用可驗證名額", prioritizeKnownLengthCandidates),
            ("總長變動不算同一檔案驗證", rejectChangingContentLength),
            ("快取檔頭後仍遵守剩餘預算", respectBudgetAfterCachedHeader),
            ("後段逾時仍遵守總預算", respectBudgetDuringValidation),
            ("最多六個探測並行", capConcurrency),
        ]
        var failed = 0
        for (name, check) in checks {
            do {
                try await check()
                print("PASS: \(name)")
            } catch {
                failed += 1
                print("FAIL: \(name): \(error)")
            }
        }
        print("\(checks.count - failed)/\(checks.count) CDN startup checks passed")
        if failed > 0 { exit(1) }
    }
}
