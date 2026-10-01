import Foundation

@main
struct PlayerExitChecks {
    static func main() {
        var confirmation = PlayerExitConfirmation()
        precondition(confirmation.requestExit(at: 0, menuPressID: 0) == .ignore,
                     "沒有實體返回按鍵時不可計入退出確認")
        precondition(confirmation.requestExit(at: 1, menuPressID: 1) == .showPrompt)
        precondition(confirmation.requestExit(at: 1.1, menuPressID: 1) == .ignore,
                     "同次按下／放開的重複 callback 不可退出")
        precondition(confirmation.requestExit(at: 2, menuPressID: 2) == .exit)
        precondition(confirmation.requestExit(at: 2.1, menuPressID: 2) == .ignore,
                     "退出後的重複 callback 不可再次顯示提示")
        precondition(confirmation.requestExit(at: 10, menuPressID: 3) == .showPrompt)
        precondition(confirmation.requestExit(at: 13, menuPressID: 4) == .showPrompt,
                     "確認期限到期後需要重新按兩次")
        precondition(confirmation.requestExit(at: 13.1, menuPressID: 3) == .ignore,
                     "延遲送達的舊按鍵不可算成第二次")
        confirmation.reset()
        precondition(confirmation.requestExit(at: 14, menuPressID: 4) == .ignore,
                     "提示重設後同一實體按鍵不能重新計數")
        precondition(confirmation.requestExit(at: 15, menuPressID: 5) == .showPrompt)
        precondition(confirmation.requestExit(at: 17.9, menuPressID: 6) == .exit)
        print("PASS: player exit confirmation (11 checks)")
    }
}
