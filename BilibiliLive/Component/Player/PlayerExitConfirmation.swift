import Foundation

struct PlayerExitConfirmation {
    enum Result {
        case showPrompt, ignore, exit
    }

    static let timeout: TimeInterval = 3
    private var lastRequestPressID: UInt64 = 0
    private var pendingPressID: UInt64?
    private var expiresAt: TimeInterval = 0

    mutating func requestExit(at now: TimeInterval, menuPressID: UInt64) -> Result {
        // callback 必須屬於新的實體按鍵；舊事件即使延遲到提示逾時後也不能重算。
        guard menuPressID > lastRequestPressID else { return .ignore }
        lastRequestPressID = menuPressID
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
}
