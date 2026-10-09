import Foundation

struct PlayerExitConfirmation {
    enum Result {
        case showPrompt, ignore, exit
    }

    static let timeout: TimeInterval = 3
    static let controlsDismissQuietPeriod: TimeInterval = 1
    private var lastRequestPressID: UInt64 = 0
    private var pendingPressID: UInt64?
    private var expiresAt: TimeInterval = 0
    private var controlsVisible = false
    private var controlsTransitionID: UInt64 = 0
    private var controlsTransitionInProgress = false
    private var suppressedUntil: TimeInterval = -.infinity
    private var suppressedThroughPressID: UInt64 = 0

    /// 追蹤 AVKit 真正的控制列轉場；showsPlaybackControls 只是功能開關。
    mutating func controlsWillTransition(to visible: Bool, at now: TimeInterval,
                                         menuPressID: UInt64) -> UInt64
    {
        controlsVisible = visible
        controlsTransitionID &+= 1
        controlsTransitionInProgress = true
        suppressMenuPresses(at: now, through: menuPressID)
        return controlsTransitionID
    }

    mutating func controlsDidTransition(_ transitionID: UInt64, at now: TimeInterval) {
        // 舊動畫的 completion 不能解除較新轉場的保護。
        guard transitionID == controlsTransitionID else { return }
        controlsTransitionInProgress = false
        suppressedUntil = max(suppressedUntil, now + Self.controlsDismissQuietPeriod)
    }

    /// began 與 ended/cancelled 都記錄，長按必須從放開後才開始計算安靜期。
    mutating func recordMenuPress(at now: TimeInterval, menuPressID: UInt64) {
        guard menuPressID > 0 else { return }
        if controlsVisible || controlsTransitionInProgress || now < suppressedUntil ||
            menuPressID <= suppressedThroughPressID
        {
            suppressMenuPresses(at: now, through: menuPressID)
        }
    }

    mutating func requestExit(at now: TimeInterval, menuPressID: UInt64) -> Result {
        // callback 必須屬於新的實體按鍵；舊事件即使延遲到提示逾時後也不能重算。
        guard menuPressID > lastRequestPressID else { return .ignore }
        lastRequestPressID = menuPressID
        guard !controlsVisible, !controlsTransitionInProgress, now >= suppressedUntil,
              menuPressID > suppressedThroughPressID
        else {
            reset()
            return .ignore
        }
        if pendingPressID != nil, now < expiresAt {
            reset()
            return .exit
        }
        pendingPressID = menuPressID
        expiresAt = now + Self.timeout
        return .showPrompt
    }

    mutating func reset() {
        pendingPressID = nil
        expiresAt = 0
    }

    private mutating func suppressMenuPresses(at now: TimeInterval, through menuPressID: UInt64) {
        reset()
        suppressedThroughPressID = max(suppressedThroughPressID, menuPressID)
        suppressedUntil = max(suppressedUntil, now + Self.controlsDismissQuietPeriod)
    }
}
