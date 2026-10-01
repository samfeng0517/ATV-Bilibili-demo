import Foundation

/// 以播放進度與單調時鐘偵測持續卡頓，不依賴可能尚未產生的 AVPlayer access log。
struct PlaybackStallMonitor {
    let stallDuration: TimeInterval
    let recoveryCooldown: TimeInterval

    private var lastPosition: TimeInterval?
    private var stalledSince: TimeInterval?
    private var lastRecoveryAttempt: TimeInterval?

    init(stallDuration: TimeInterval = 10, recoveryCooldown: TimeInterval = 30) {
        self.stallDuration = stallDuration
        self.recoveryCooldown = recoveryCooldown
    }

    /// 暫停、結束與切換播放器時清掉舊進度，保留恢復冷卻時間以免連續換源。
    mutating func resetPlayback() {
        lastPosition = nil
        stalledSince = nil
    }

    mutating func shouldRecover(at now: TimeInterval,
                                position: TimeInterval,
                                isPlayingOrWaiting: Bool,
                                isRecovering: Bool) -> Bool
    {
        guard isPlayingOrWaiting, position.isFinite else {
            resetPlayback()
            return false
        }

        let hasProgress = lastPosition.map { Self.positionChanged(from: $0, to: position) } ?? true
        lastPosition = position
        if hasProgress {
            // 正常推進或 seek 到新位置都重新計時，短暫緩衝不觸發切換。
            stalledSince = now
            return false
        }
        guard let stalledSince, now - stalledSince >= stallDuration, !isRecovering else { return false }
        if let lastRecoveryAttempt, now - lastRecoveryAttempt < recoveryCooldown { return false }
        lastRecoveryAttempt = now
        return true
    }

    static func positionChanged(from oldPosition: TimeInterval, to newPosition: TimeInterval) -> Bool {
        oldPosition.isFinite && newPosition.isFinite && abs(newPosition - oldPosition) >= 0.05
    }
}
