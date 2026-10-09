import Foundation

@main
struct PlayerExitChecks {
    private static var checkCount = 0

    static func main() {
        checkDuplicateCallbacksAndTimeout()
        checkVisibleControlsAndHideTransition()
        checkContinuousMenuBurst()
        checkQuietPeriodStartsWhenLongPressEnds()
        checkDelayedRequestForSuppressedPress()
        checkSupersededTransitionCompletion()
        checkShowingControlsResetsPendingExit()
        checkResetPreservesSuppression()
        checkHideTransitionBeforePressObserver()
        print("PASS: player exit confirmation (\(checkCount) checks)")
    }

    private static func expect(_ actual: PlayerExitConfirmation.Result,
                               _ expected: PlayerExitConfirmation.Result,
                               _ message: String)
    {
        precondition(actual == expected, message)
        checkCount += 1
    }

    /// 與實際 observer 一樣，按下及放開都更新 gate，放開後才請求退出。
    private static func press(_ confirmation: inout PlayerExitConfirmation,
                              id: UInt64, beganAt: TimeInterval,
                              endedAt: TimeInterval) -> PlayerExitConfirmation.Result
    {
        precondition(endedAt >= beganAt)
        confirmation.recordMenuPress(at: beganAt, menuPressID: id)
        confirmation.recordMenuPress(at: endedAt, menuPressID: id)
        return confirmation.requestExit(at: endedAt, menuPressID: id)
    }

    private static func checkDuplicateCallbacksAndTimeout() {
        var confirmation = PlayerExitConfirmation()
        expect(confirmation.requestExit(at: 0, menuPressID: 0), .ignore,
               "沒有實體返回按鍵時不可計入退出確認")
        expect(press(&confirmation, id: 1, beganAt: 0.9, endedAt: 1), .showPrompt,
               "控制列未顯示時第一次返回應顯示提示")
        expect(confirmation.requestExit(at: 1.1, menuPressID: 1), .ignore,
               "同次按下／放開的重複 callback 不可退出")
        expect(press(&confirmation, id: 2, beganAt: 1.9, endedAt: 2), .exit,
               "期限內新的第二次返回應退出")
        expect(confirmation.requestExit(at: 2.1, menuPressID: 2), .ignore,
               "退出後的重複 callback 不可再次顯示提示")
        expect(press(&confirmation, id: 3, beganAt: 9.9, endedAt: 10), .showPrompt,
               "新一輪返回應顯示提示")
        expect(press(&confirmation, id: 4, beganAt: 12.9, endedAt: 13), .showPrompt,
               "確認期限到期後需要重新按兩次")
        expect(confirmation.requestExit(at: 13.1, menuPressID: 3), .ignore,
               "延遲送達的舊按鍵不可算成第二次")
        confirmation.reset()
        expect(confirmation.requestExit(at: 14, menuPressID: 4), .ignore,
               "提示重設後同一實體按鍵不能重新計數")
        expect(press(&confirmation, id: 5, beganAt: 14.9, endedAt: 15), .showPrompt,
               "重設後需要新的第一次返回")
        expect(press(&confirmation, id: 6, beganAt: 17.8, endedAt: 17.9), .exit,
               "新提示的期限內應可正常退出")
    }

    private static func checkVisibleControlsAndHideTransition() {
        var confirmation = PlayerExitConfirmation()
        let show = confirmation.controlsWillTransition(to: true, at: 0, menuPressID: 0)
        confirmation.controlsDidTransition(show, at: 0.2)
        expect(press(&confirmation, id: 1, beganAt: 5, endedAt: 5.1), .ignore,
               "控制列仍可見時，即使已超過安靜期也不可提示退出")

        let hide = confirmation.controlsWillTransition(to: false, at: 6, menuPressID: 1)
        expect(press(&confirmation, id: 2, beganAt: 8, endedAt: 8.1), .ignore,
               "隱藏動畫尚未完成時不可因固定期限已過而解除保護")
        confirmation.controlsDidTransition(hide, at: 9)
        expect(press(&confirmation, id: 3, beganAt: 9.5, endedAt: 9.6), .ignore,
               "隱藏動畫剛完成的連按仍應只關閉介面")
        expect(press(&confirmation, id: 4, beganAt: 10.7, endedAt: 10.8), .showPrompt,
               "介面關閉且安靜期結束後才允許第一次退出確認")
        expect(press(&confirmation, id: 5, beganAt: 11, endedAt: 11.1), .exit,
               "安靜期後正常第二次返回應退出")
    }

    private static func checkContinuousMenuBurst() {
        var confirmation = PlayerExitConfirmation()
        let hide = confirmation.controlsWillTransition(to: false, at: 0, menuPressID: 0)
        confirmation.controlsDidTransition(hide, at: 0.2)
        var lastEndedAt: TimeInterval = 0
        for id in UInt64(1)...20 {
            let beganAt = 0.4 + Double(id - 1) * 0.4
            lastEndedAt = beganAt + 0.1
            expect(press(&confirmation, id: id, beganAt: beganAt, endedAt: lastEndedAt), .ignore,
                   "連按第 \(id) 次仍不可退出；安靜期必須隨每次按鍵延長")
        }
        let resumedAt = lastEndedAt + PlayerExitConfirmation.controlsDismissQuietPeriod + 0.1
        expect(press(&confirmation, id: 21, beganAt: resumedAt, endedAt: resumedAt + 0.1), .showPrompt,
               "持續多秒連按結束後，下一輪應從第一次提示重新開始")
        expect(press(&confirmation, id: 22, beganAt: resumedAt + 0.2, endedAt: resumedAt + 0.3), .exit,
               "防連按保護不應永久禁用正常兩次退出")
    }

    private static func checkQuietPeriodStartsWhenLongPressEnds() {
        var confirmation = PlayerExitConfirmation()
        let hide = confirmation.controlsWillTransition(to: false, at: 0, menuPressID: 0)
        confirmation.controlsDidTransition(hide, at: 0.1)
        expect(press(&confirmation, id: 1, beganAt: 0.5, endedAt: 10), .ignore,
               "關閉介面時長按返回，放開不能成為退出確認")
        expect(press(&confirmation, id: 2, beganAt: 10.5, endedAt: 10.6), .ignore,
               "長按的安靜期必須由放開計算，不能由按下計算")
        expect(press(&confirmation, id: 3, beganAt: 11.7, endedAt: 11.8), .showPrompt,
               "長按與隨後連按都停止後才恢復退出確認")
    }

    private static func checkDelayedRequestForSuppressedPress() {
        var confirmation = PlayerExitConfirmation()
        let hide = confirmation.controlsWillTransition(to: false, at: 0, menuPressID: 0)
        confirmation.controlsDidTransition(hide, at: 0.1)
        confirmation.recordMenuPress(at: 0.2, menuPressID: 1)
        confirmation.recordMenuPress(at: 0.3, menuPressID: 1)
        // 此按鍵先前未呼叫 requestExit，避免僅靠 request ID 去重就讓測試通過。
        expect(confirmation.requestExit(at: 10, menuPressID: 1), .ignore,
               "用來關閉介面的按鍵，即使 callback 晚於安靜期才到達也不可計數")
        expect(press(&confirmation, id: 2, beganAt: 10.1, endedAt: 10.2), .showPrompt,
               "延遲 callback 不應提前建立退出確認")
        expect(confirmation.requestExit(at: 20, menuPressID: 2), .ignore,
               "同個實體按鍵即使晚於提示期限也不可再次計數")
        expect(press(&confirmation, id: 3, beganAt: 20.1, endedAt: 20.2), .showPrompt,
               "逾時後新的按鍵仍需重新開始確認")
    }

    private static func checkSupersededTransitionCompletion() {
        var confirmation = PlayerExitConfirmation()
        let show = confirmation.controlsWillTransition(to: true, at: 0, menuPressID: 0)
        let hide = confirmation.controlsWillTransition(to: false, at: 0.1, menuPressID: 0)
        confirmation.controlsDidTransition(show, at: 0.2)
        expect(press(&confirmation, id: 1, beganAt: 2, endedAt: 2.1), .ignore,
               "舊顯示動畫的 completion 不可解除新隱藏動畫的保護")
        confirmation.controlsDidTransition(hide, at: 3)
        confirmation.controlsDidTransition(show, at: 20)
        expect(press(&confirmation, id: 2, beganAt: 20.1, endedAt: 20.2), .showPrompt,
               "晚到的舊 completion 也不可重新延長已結束的保護")
    }

    private static func checkShowingControlsResetsPendingExit() {
        var confirmation = PlayerExitConfirmation()
        expect(press(&confirmation, id: 1, beganAt: 0, endedAt: 0.1), .showPrompt,
               "先建立一個尚未逾時的退出提示")
        let show = confirmation.controlsWillTransition(to: true, at: 0.2, menuPressID: 1)
        confirmation.controlsDidTransition(show, at: 0.3)
        let hide = confirmation.controlsWillTransition(to: false, at: 0.4, menuPressID: 1)
        confirmation.controlsDidTransition(hide, at: 0.5)
        expect(press(&confirmation, id: 2, beganAt: 1.6, endedAt: 1.7), .showPrompt,
               "控制列重新開關後，即使舊提示尚未逾時也不能沿用為第二次返回")
        expect(press(&confirmation, id: 3, beganAt: 1.8, endedAt: 1.9), .exit,
               "介面關閉後的新提示仍應支援正常確認退出")
    }

    private static func checkResetPreservesSuppression() {
        var confirmation = PlayerExitConfirmation()
        let hide = confirmation.controlsWillTransition(to: false, at: 0, menuPressID: 0)
        confirmation.controlsDidTransition(hide, at: 0.1)
        expect(press(&confirmation, id: 1, beganAt: 0.2, endedAt: 0.3), .ignore,
               "關閉控制列的按鍵應被保護")
        confirmation.reset()
        expect(press(&confirmation, id: 2, beganAt: 0.8, endedAt: 0.9), .ignore,
               "提示 timeout 或生命週期 reset 不可清除仍有效的連按保護")
        let quietBoundary = 0.9 + PlayerExitConfirmation.controlsDismissQuietPeriod
        expect(press(&confirmation, id: 3, beganAt: quietBoundary, endedAt: quietBoundary), .showPrompt,
               "安靜期剛好結束時應可開始新確認，不需額外多等一輪")
    }

    private static func checkHideTransitionBeforePressObserver() {
        var confirmation = PlayerExitConfirmation()
        // AVKit 的轉場 delegate 可能先於同次按鍵的 observer 收到通知。
        let hide = confirmation.controlsWillTransition(to: false, at: 0, menuPressID: 0)
        confirmation.controlsDidTransition(hide, at: 0)
        expect(press(&confirmation, id: 1, beganAt: 0, endedAt: 0.1), .ignore,
               "隱藏轉場先於 observer 時，同一關閉按鍵仍不可建立退出提示")
        expect(press(&confirmation, id: 2, beganAt: 1.2, endedAt: 1.3), .showPrompt,
               "轉場與按鍵排序不同也不能永久鎖住退出")
    }
}
