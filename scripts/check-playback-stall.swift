import Foundation

// 與正式 PlaybackStallMonitor 編譯；以單調時間與播放位置重現卡頓，不需要外網或 AVPlayer。
private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

@main
private enum PlaybackStallChecks {
    static func main() throws {
        let checks: [(String, () throws -> Void)] = [
            ("waiting 起播、沒有 access log 或 stall notification 仍於 10 秒恢復", waitingWithoutLog),
            ("假 playing 但位置凍結仍偵測卡頓", frozenPlayback),
            ("正常推進與短暫等待不觸發", progressingPlayback),
            ("手動暫停清掉卡頓時間，恢復播放後重新計時", manualPause),
            ("前後 seek 重新計時，不沿用舊位置卡頓", seeking),
            ("恢復中的 timer 與 notification 不重複恢復", recoveryInProgress),
            ("CDN 切換或失敗後保留 30 秒冷卻", recoveryCooldown),
            ("無效位置不觸發，恢復有效位置後重新計時", invalidPosition),
            ("恢復期間已前進或 seek 時取消舊位置的 CDN 切換", progressDuringRecovery),
        ]
        var failures = 0
        for (name, check) in checks {
            do {
                try check()
                print("PASS: \(name)")
            } catch {
                failures += 1
                print("FAIL: \(name): \(error)")
            }
        }
        print("\(checks.count - failures)/\(checks.count) playback stall checks passed")
        if failures > 0 { throw CheckFailure(description: "playback stall regression failed") }
    }

    private static func sample(_ monitor: inout PlaybackStallMonitor,
                               at now: Double, position: Double = 0,
                               active: Bool = true, recovering: Bool = false) -> Bool
    {
        monitor.shouldRecover(at: now, position: position,
                              isPlayingOrWaiting: active, isRecovering: recovering)
    }

    private static func waitingWithoutLog() throws {
        var monitor = PlaybackStallMonitor()
        try expect(!sample(&monitor, at: 0), "首次等待不能立刻切換")
        try expect(!sample(&monitor, at: 9.99), "未滿 10 秒不能切換")
        try expect(sample(&monitor, at: 10), "無任何 access log 仍應切換")
    }

    private static func frozenPlayback() throws {
        var monitor = PlaybackStallMonitor()
        _ = sample(&monitor, at: 100, position: 35)
        try expect(sample(&monitor, at: 110, position: 35), "狀態為 playing 不代表進度有前進")
    }

    private static func progressingPlayback() throws {
        var monitor = PlaybackStallMonitor()
        for second in 0...60 {
            try expect(!sample(&monitor, at: Double(second), position: Double(second) * 0.5),
                       "0.5x 正常播放不得切換")
        }
        try expect(!sample(&monitor, at: 69, position: 30), "短暫緩衝不得切換")
        try expect(!sample(&monitor, at: 70, position: 31), "恢復進度後清掉等待時間")
        try expect(!sample(&monitor, at: 79, position: 31), "新一輪等待未滿門檻不得切換")
    }

    private static func manualPause() throws {
        var monitor = PlaybackStallMonitor()
        _ = sample(&monitor, at: 0, position: 20)
        _ = sample(&monitor, at: 9, position: 20)
        try expect(!sample(&monitor, at: 10, position: 20, active: false), "使用者暫停不得切換")
        try expect(!sample(&monitor, at: 100, position: 20, active: false), "長時間暫停不得切換")
        try expect(!sample(&monitor, at: 101, position: 20), "恢復播放需重新計時")
        try expect(!sample(&monitor, at: 110, position: 20), "舊的卡頓時間不得帶入")
        try expect(sample(&monitor, at: 111, position: 20), "恢復後持續卡頓才切換")
    }

    private static func seeking() throws {
        for target in [5.0, 100.0] {
            var monitor = PlaybackStallMonitor()
            _ = sample(&monitor, at: 0, position: 20)
            _ = sample(&monitor, at: 9, position: 20)
            try expect(!sample(&monitor, at: 10, position: target), "seek 不能當成旧位置持續卡頓")
            try expect(!sample(&monitor, at: 19, position: target), "seek 後重新計時")
            try expect(sample(&monitor, at: 20, position: target), "seek 後持續卡住仍可恢復")
        }
    }

    private static func recoveryInProgress() throws {
        var monitor = PlaybackStallMonitor()
        _ = sample(&monitor, at: 0)
        try expect(sample(&monitor, at: 10), "首次恢復應啟動")
        try expect(!sample(&monitor, at: 10), "同時收到 notification 不可重複恢復")
        try expect(!sample(&monitor, at: 40, recovering: true), "冷卻結束但仍恢復中不得重入")
        try expect(sample(&monitor, at: 41), "恢復失敗且仍卡住可再嘗試")
    }

    private static func recoveryCooldown() throws {
        var monitor = PlaybackStallMonitor()
        _ = sample(&monitor, at: 0)
        try expect(sample(&monitor, at: 10), "首次恢復應啟動")
        monitor.resetPlayback()
        _ = sample(&monitor, at: 11, position: 25)
        try expect(!sample(&monitor, at: 21, position: 25), "切換後再次卡住仍需尊重冷卻")
        try expect(!sample(&monitor, at: 39.99, position: 25), "冷卻未滿不得反覆切換")
        try expect(sample(&monitor, at: 40, position: 25), "冷卻結束且仍卡住可切換")
    }

    private static func invalidPosition() throws {
        var monitor = PlaybackStallMonitor()
        _ = sample(&monitor, at: 0)
        try expect(!sample(&monitor, at: 10, position: .nan), "未知時間不得切換")
        try expect(!sample(&monitor, at: 20, position: .infinity), "無限時間不得切換")
        try expect(!sample(&monitor, at: 21), "恢復有效時間後重新計時")
        try expect(sample(&monitor, at: 31), "有效時間持續卡頓可切換")
    }

    private static func progressDuringRecovery() throws {
        try expect(!PlaybackStallMonitor.positionChanged(from: 20, to: 20.01), "時間微小誤差不是恢復")
        try expect(PlaybackStallMonitor.positionChanged(from: 20, to: 20.5), "進度已推進應取消恢復")
        try expect(PlaybackStallMonitor.positionChanged(from: 20, to: 5), "向後 seek 也應取消旧位置恢復")
    }
}
