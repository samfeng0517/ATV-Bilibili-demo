//
//  CommonPlayerViewController.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/23.
//

import AVKit
import UIKit

class CommonPlayerViewController: UIViewController {
    private let playerVC = AVPlayerViewController()
    private var activePlugins = [CommonPlayerPlugin]()
    private var observations = Set<NSKeyValueObservation>()
    private var rateObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var playToEndObserver: Any?
    private var playbackStalledObserver: Any?
    private var subtitleSelectionObserver: Any?
    private var selectedSubtitleOption: AVMediaSelectionOption?
    private var subtitleSelectionGroup: AVMediaSelectionGroup?
    private var subtitleSelectionTask: Task<Void, Never>?
    private var preferredSubtitleLanguage: String?
    private var preferredSubtitleName: String?
    private var audioSelectionTask: Task<Void, Never>?
    private var audioSelectionGroup: AVMediaSelectionGroup?
    private var preferredAudioLanguage: String?
    private var preferredAudioName: String?
    private let menuPressObserver = PlayerMenuPressObserver()
    private var playbackBeforeMenuPress: PlayerMenuPlaybackSnapshot?
    private weak var exitAlert: UIAlertController?
    private var lastExitRequestPressID: UInt64 = 0
    private var exitAlertClosedAt: TimeInterval = -.infinity
    private var consumesMenuPress = false
    private var isEnd = false
    private var isRestoringFromPip = false
    var showsPlaybackControls = true
    var allowsPictureInPicturePlayback = true

    deinit {
        cleanUpPlayerOnExit(force: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // UIKit 的互動式 dismiss 也必須經過播放器自己的返回確認。
        isModalInPresentation = true
        addChild(playerVC)
        view.addSubview(playerVC.view)
        playerVC.didMove(toParent: self)
        playerVC.view.snp.makeConstraints { $0.edges.equalToSuperview() }
        playerVC.showsPlaybackControls = showsPlaybackControls
        playerVC.allowsPictureInPicturePlayback = allowsPictureInPicturePlayback
        // 保留 AVKit 原生快轉、倒轉與連續操作的行為。
        playerVC.delegate = self
        // 只觀察實體按鍵，不攔截 AVKit 收起控制列或子選單的 Menu 行為。
        menuPressObserver.onMenuPressBegan = { [weak self] in
            self?.capturePlaybackBeforeMenuPress()
        }
        view.addGestureRecognizer(menuPressObserver)

        let playerObservation = playerVC.observe(\.player, options: [.old, .new]) { [weak self] vc, obs in
            Logger.debug("player changed: \(String(describing: obs.oldValue)) -> \(String(describing: obs.newValue))")
            if let oldPlayer = obs.oldValue, let oldPlayer {
                self?.activePlugins.forEach { $0.playerDidCleanUp(player: oldPlayer) }
            }
            self?.playerDidChange(player: vc.player)
        }
        observations.insert(playerObservation)
        activePlugins.forEach { $0.playerDidLoad(playerVC: playerVC) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 離開確認對話框蓋住播放器時不算離開，外掛的 dismiss hook 不能執行。
        guard exitAlert == nil else { return }
        resetExitConfirmation()
        activePlugins.forEach { $0.playerDidDismiss(playerVC: playerVC) }
        cleanUpPlayerOnExit()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return [playerVC.view]
    }

    // AVKit 的 gesture 仍可先收起控制列／子選單；未處理的 Menu 到達
    // 父容器後必須在此消耗，不能再交給 presenting controller 或系統。
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if shouldConsumeMenuPress, presses.contains(where: { $0.type == .menu }) {
            consumesMenuPress = true
        }
        let remaining = pressesToForward(presses)
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = pressesToForward(presses)
        if !remaining.isEmpty { super.pressesChanged(remaining, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = pressesToForward(presses)
        if remaining.count != presses.count {
            let pressID = menuPressObserver.lastMenuPressID
            DispatchQueue.main.async { [weak self] in
                self?.requestExitConfirmation(menuPressID: pressID)
            }
            consumesMenuPress = false
        }
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = pressesToForward(presses)
        if remaining.count != presses.count { consumesMenuPress = false }
        if !remaining.isEmpty { super.pressesCancelled(remaining, with: event) }
    }

    private var shouldConsumeMenuPress: Bool {
        // dismiss 動畫期間也要攔住餘下的返回事件，避免傳到下層頁面／系統。
        viewIfLoaded?.window != nil && (isBeingDismissed || UIViewController.topMostViewController() === self)
    }

    private func pressesToForward(_ presses: Set<UIPress>) -> Set<UIPress> {
        guard consumesMenuPress || shouldConsumeMenuPress else { return presses }
        return Set(presses.filter { $0.type != .menu })
    }

    func addPlugin(plugin: CommonPlayerPlugin) {
        if activePlugins.contains(where: { $0 == plugin }) {
            return
        }
        plugin.addViewToPlayerOverlay(container: playerVC.contentOverlayView!)
        activePlugins.append(plugin)
        plugin.playerDidLoad(playerVC: playerVC)
        if playerVC.transportBarCustomMenuItems.isEmpty == false {
            updateMenus()
        }
    }

    func removePlugin(plugin: CommonPlayerPlugin) {
        let removingPlugins = activePlugins.filter { $0 == plugin }
        removingPlugins.forEach { $0.playerWillCleanUp(playerVC: playerVC) }
        if let player = playerVC.player {
            removingPlugins.forEach { $0.playerDidCleanUp(player: player) }
        }
        activePlugins.removeAll { $0 == plugin }
    }

    func removeAllPlugins() {
        guard !activePlugins.isEmpty else { return }
        activePlugins.forEach { $0.playerWillCleanUp(playerVC: playerVC) }
        if let player = playerVC.player {
            Logger.debug("removeAllPlugins: clean up player: \(player)")
            activePlugins.forEach { $0.playerDidCleanUp(player: player) }
        }
        activePlugins.removeAll()
    }

    func playerWillStart(player: AVPlayer) {}
    func playerDidStart(player: AVPlayer) {}
    func playerDidEnd(player: AVPlayer) {}
    func playerDidStall(player: AVPlayer) {}
    func playerDidFail(player: AVPlayer) {}

    func showErrorAlertAndExit(title: String = "播放失败", message: String = "未知错误") {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let actionOk = UIAlertAction(title: "OK", style: .default) {
            [weak self] _ in
            self?.dismiss(animated: true, completion: nil)
        }
        alertController.addAction(actionOk)
        present(alertController, animated: true, completion: nil)
    }

    func updateMenus() {
        var menus = [UIMenuElement]()
        for activePlugin in activePlugins {
            let newMenus = activePlugin.addMenuItems(current: &menus)
            menus.append(contentsOf: newMenus)
        }

        let identifier: (UIMenuElement) -> String? = {
            if let menu = $0 as? UIMenu { return menu.identifier.rawValue }
            if let action = $0 as? UIAction { return action.identifier.rawValue }
            return nil
        }

        // 彈幕設定不再佔用頂層按鈕，改接在播放設定既有項目的最後。
        let danmuSettingMenus = menus.compactMap { $0 as? UIMenu }.filter { $0.identifier.rawValue == "danmuSetting" }
        if let settingIndex = menus.firstIndex(where: { identifier($0) == "setting" }),
           let settingMenu = menus[settingIndex] as? UIMenu
        {
            let danmuSettingItems = danmuSettingMenus.flatMap(\.children)
            menus[settingIndex] = settingMenu.replacingChildren(settingMenu.children + danmuSettingItems)
        }
        menus.removeAll { identifier($0) == "danmuSetting" }

        // 字幕、音頻與子母畫面由 AVPlayer 管理；固定其餘自訂項目的相對位置。
        let orderedIdentifiers = ["playSpeed", "quality", "danmuToggle"]
        let orderedMenus = orderedIdentifiers.flatMap { expectedIdentifier in
            menus.filter { identifier($0) == expectedIdentifier }
        }
        let settingMenus = menus.filter { identifier($0) == "setting" }
        let knownIdentifiers = Set(orderedIdentifiers + ["setting"])
        let otherMenus = menus.filter { element in
            guard let elementIdentifier = identifier(element) else { return true }
            return !knownIdentifiers.contains(elementIdentifier)
        }
        menus = orderedMenus + otherMenus + settingMenus

        playerVC.transportBarCustomMenuItems = menus
    }

    func stopPlayback() {
        cleanUpPlayerOnExit(force: true)
    }

    func currentPlaybackTimeInSeconds() -> Int? {
        guard let seconds = playerVC.player?.currentTime().seconds,
              seconds.isFinite,
              seconds > 0
        else {
            return nil
        }
        return Int(seconds.rounded(.down))
    }

    private func cleanUpPlayerOnExit(force: Bool = false) {
        let isPictureInPictureRunning = PipRecorder.shared.playingPipViewController.contains { $0.playerVC == playerVC }
        let shouldCleanUp = force || ((isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true) && !isPictureInPictureRunning)
        guard shouldCleanUp else { return }

        cleanUpObserver()

        let player = playerVC.player
        player?.pause()
        // Plugins may still be preparing the first AVPlayer. Always run their
        // cleanup hook even when playerVC.player has not been installed yet.
        removeAllPlugins()
        player?.replaceCurrentItem(with: nil)
        playerVC.player = nil
    }

    private func cleanUpObserver() {
        cleanUpSubtitleSelection()
        cleanUpAudioSelection()
        rateObserver = nil
        statusObserver = nil
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
        }
        playToEndObserver = nil
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
        }
        playbackStalledObserver = nil
    }

    /// 返回鍵只會開啟或關閉確認對話框；離開播放器必須移到「離開」再按確認鍵，
    /// 連按返回因此不會退出播放，也不會把按鍵漏到下層頁面。
    private func requestExitConfirmation(menuPressID: UInt64) {
        guard UIViewController.topMostViewController() === self,
              viewIfLoaded?.window != nil, !isBeingDismissed, exitAlert == nil,
              menuPressID == menuPressObserver.lastMenuPressID
        else { return }
        // AVKit 與 responder chain 可能為同一次按鍵各請求一次，只處理第一次。
        if menuPressID != 0, menuPressID == lastExitRequestPressID { return }
        lastExitRequestPressID = menuPressID
        // 關閉對話框的那次返回不能立刻再開一個。
        guard ProcessInfo.processInfo.systemUptime - exitAlertClosedAt > 0.5 else {
            restorePlaybackAfterCancelledExit()
            return
        }
        let alert = UIAlertController(title: "離開播放？", message: nil, preferredStyle: .alert)
        let exitAction = UIAlertAction(title: "離開", style: .default) { [weak self] _ in
            self?.exitAlert = nil
            self?.resetExitConfirmation()
            self?.dismiss(animated: true)
        }
        alert.addAction(exitAction)
        let continueAction = UIAlertAction(title: "繼續播放", style: .cancel) { [weak self] _ in
            self?.exitAlert = nil
            self?.exitAlertClosedAt = ProcessInfo.processInfo.systemUptime
        }
        alert.addAction(continueAction)
        // 預設焦點放在繼續播放，誤按確認鍵也不會離開。
        alert.preferredAction = continueAction
        exitAlert = alert
        present(alert, animated: true)
        // AVKit 可能先 pause 再詢問是否離開；對話框顯示期間維持原本的播放狀態。
        restorePlaybackAfterCancelledExit()
    }

    private func capturePlaybackBeforeMenuPress() {
        playbackBeforeMenuPress = nil
        guard UIViewController.topMostViewController() === self, !isEnd,
              let player = playerVC.player, let item = player.currentItem,
              player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        else { return }
        // waiting 時 rate 可能為 0；defaultRate 保留 AVKit 選擇的播放倍速。
        let rate = player.rate != 0 ? player.rate : player.defaultRate
        playbackBeforeMenuPress = PlayerMenuPlaybackSnapshot(player: player, item: item,
                                                             rate: rate, menuPressID: menuPressObserver.lastMenuPressID)
    }

    private func restorePlaybackAfterCancelledExit() {
        let snapshot = playbackBeforeMenuPress
        // 每次實體按鍵只消費一次，避免稍後重複 callback 蓋過使用者的暫停。
        playbackBeforeMenuPress = nil
        guard let snapshot, snapshot.menuPressID == menuPressObserver.lastMenuPressID,
              let player = snapshot.player, let item = snapshot.item,
              playerVC.player === player, player.currentItem === item,
              player.rate == 0, player.timeControlStatus == .paused,
              item.status != .failed, !isEnd, !isBeingDismissed,
              viewIfLoaded?.window != nil
        else { return }
        // AVKit 可能先 pause 再詢問是否離開；未離開時還原按鍵前的播放意圖。
        player.rate = snapshot.rate
    }

    private func resetExitConfirmation() {
        playbackBeforeMenuPress = nil
        exitAlert?.dismiss(animated: false)
        exitAlert = nil
    }
}

extension CommonPlayerViewController {
    private func playerDidChange(player: AVPlayer?) {
        cleanUpSubtitleSelection()
        cleanUpAudioSelection()
        if let player {
            activePlugins.forEach { $0.playerDidChange(player: player) }
            rateObserver = player.observe(\.rate, options: [.old, .new]) {
                [weak self] _player, obs in
                DispatchQueue.main.async { [weak self] in
                    self?.playerRateDidChange(player: player)
                }
            }
            if let playItem = player.currentItem {
                observePlayerItem(playItem)
            }
            updateMenus()
        } else {
            cleanUpObserver()
        }
    }

    private func cleanUpSubtitleSelection() {
        subtitleSelectionTask?.cancel()
        subtitleSelectionTask = nil
        subtitleSelectionGroup = nil
        if let subtitleSelectionObserver {
            NotificationCenter.default.removeObserver(subtitleSelectionObserver)
        }
        subtitleSelectionObserver = nil
        selectedSubtitleOption = nil
    }

    private func cleanUpAudioSelection() {
        audioSelectionTask?.cancel()
        audioSelectionTask = nil
        audioSelectionGroup = nil
    }

    private func observeAudioSelection(_ item: AVPlayerItem) {
        cleanUpAudioSelection()
        guard playerVC.player?.appliesMediaSelectionCriteriaAutomatically == false else { return }
        audioSelectionTask = Task { @MainActor [weak self, weak item] in
            guard let item,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  !Task.isCancelled,
                  let self, self.playerVC.player?.currentItem === item
            else { return }
            self.audioSelectionGroup = group
            guard self.preferredAudioLanguage != nil || self.preferredAudioName != nil else { return }
            let option = group.options.first { self.preferredAudioName != nil && $0.displayName == self.preferredAudioName } ??
                group.options.first { self.preferredAudioLanguage != nil && $0.extendedLanguageTag == self.preferredAudioLanguage }
            if let option {
                item.select(option, in: group)
            }
        }
    }

    private func observeSubtitleSelection(_ item: AVPlayerItem) {
        cleanUpSubtitleSelection()
        // 只管理明確停用自動媒體選擇的影片播放器，不介入直播等其他來源。
        guard playerVC.player?.appliesMediaSelectionCriteriaAutomatically == false else { return }
        subtitleSelectionTask = Task { @MainActor [weak self, weak item] in
            guard let item,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  !Task.isCancelled,
                  let self, self.playerVC.player?.currentItem === item
            else { return }
            self.subtitleSelectionGroup = group
            let preferredOption = group.options.first { self.preferredSubtitleName != nil && $0.displayName == self.preferredSubtitleName } ??
                group.options.first { self.preferredSubtitleLanguage != nil && $0.extendedLanguageTag == self.preferredSubtitleLanguage }
            self.selectedSubtitleOption = preferredOption
            item.select(preferredOption, in: group)
            self.subtitleSelectionObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
            ) { [weak self, weak item] _ in
                // 使用者選單操作也會先發出通知。等 delegate 記錄新選擇後再比對，
                // 避免把使用者剛開啟的字幕還原成關閉。
                DispatchQueue.main.async { [weak self, weak item] in
                    guard let self, let item,
                          self.subtitleSelectionObserver != nil,
                          self.playerVC.player?.currentItem === item,
                          let group = self.subtitleSelectionGroup
                    else { return }
                    let selected = item.currentMediaSelection.selectedMediaOption(in: group)
                    guard selected != self.selectedSubtitleOption else { return }
                    item.select(self.selectedSubtitleOption, in: group)
                }
            }
        }
    }

    private func playerRateDidChange(player: AVPlayer) {
        if player.rate > 0 {
            activePlugins.forEach { $0.playerDidStart(player: player) }
            playerDidStart(player: player)
        } else if player.rate == 0 {
            if !isEnd {
                activePlugins.forEach { $0.playerDidPause(player: player) }
            }
        }
    }

    private func observePlayerItem(_ playerItem: AVPlayerItem) {
        observeSubtitleSelection(playerItem)
        observeAudioSelection(playerItem)
        // KVO 不一定能將狀態列舉轉成 oldValue/newValue；兩者皆 nil 時也可能已 ready。
        // 每個 item 分別記錄實際狀態，避免漏掉啟播或重複執行 ready hooks。
        var lastObservedStatus: AVPlayerItem.Status?
        statusObserver = playerItem.observe(\.status, options: [.initial, .new]) {
            [weak self] item, _ in
            guard let self, let player = playerVC.player,
                  player.currentItem === item
            else { return }
            let status = item.status
            guard lastObservedStatus != status else { return }
            lastObservedStatus = status
            switch status {
            case .readyToPlay:
                isEnd = false
                activePlugins.forEach { $0.playerWillStart(player: player) }
                playerWillStart(player: player)
                if !activePlugins.contains(where: { $0.handlesPlaybackStart }) {
                    player.play()
                }
            case .failed:
                activePlugins.forEach { $0.playerDidFail(player: player) }
                playerDidFail(player: player)
            default:
                break
            }
        }
        if let playToEndObserver {
            NotificationCenter.default.removeObserver(playToEndObserver)
        }
        playToEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] note in
            guard let self, let player = playerVC.player else { return }
            isEnd = true
            activePlugins.forEach { $0.playerDidEnd(player: player) }
            playerDidEnd(player: player)
        }
        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
        }
        playbackStalledObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: playerItem, queue: .main) { [weak self] _ in
            guard let self, let player = playerVC.player else { return }
            activePlugins.forEach { $0.playerDidStall(player: player) }
            playerDidStall(player: player)
        }
    }
}

extension CommonPlayerViewController: AVPlayerViewControllerDelegate {
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              didSelect mediaSelectionOption: AVMediaSelectionOption?,
                              in mediaSelectionGroup: AVMediaSelectionGroup)
    {
        if subtitleSelectionObserver != nil,
           let group = subtitleSelectionGroup,
           group == mediaSelectionGroup
        {
            // 只有字幕選單的明確操作更新偏好；系統暫時選取／取消字幕不改寫它。
            selectedSubtitleOption = mediaSelectionOption
            preferredSubtitleLanguage = mediaSelectionOption?.extendedLanguageTag
            preferredSubtitleName = mediaSelectionOption?.displayName
        } else if let group = audioSelectionGroup, group == mediaSelectionGroup {
            preferredAudioLanguage = mediaSelectionOption?.extendedLanguageTag
            preferredAudioName = mediaSelectionOption?.displayName
        }
    }

    @objc func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
        guard playerViewController === playerVC else { return false }
        let requestedAt = ProcessInfo.processInfo.systemUptime
        // 等同一個按鍵事件傳遞完畢，再讀取 observer 記錄的 press ID。
        // AVKit 即使在同一次按下／放開重複請求 dismiss，也不算第二次確認。
        DispatchQueue.main.async { [weak self] in
            // observer 可能晚於 AVKit 收到同一個 began；用事件的單調時間
            // 排除 callback 排隊期間才按下的新按鍵，不能錯綁成第二次返回。
            guard let self, self.menuPressObserver.lastMenuPressTimestamp <= requestedAt else { return }
            self.requestExitConfirmation(menuPressID: self.menuPressObserver.lastMenuPressID)
        }
        return false
    }

    @objc func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_: AVPlayerViewController) -> Bool {
        return true
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        resetExitConfirmation()
        isRestoringFromPip = false
        PipRecorder.shared.playingPipViewController.append(self)
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        PipRecorder.shared.playingPipViewController.removeAll { $0.playerVC == playerViewController }
        if !isRestoringFromPip {
            // 用户点 ✕ 关闭 PiP，清理资源
            cleanUpPlayerOnExit(force: true)
        }
        isRestoringFromPip = false
    }

    @objc func playerViewController(_ playerViewController: AVPlayerViewController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void)
    {
        isRestoringFromPip = true
        let presentedViewController = UIViewController.topMostViewController()
        guard let containerPlayer = PipRecorder.shared.playingPipViewController.first(where: { $0.playerVC == playerViewController }) else {
            completionHandler(false)
            return
        }
        if presentedViewController is CommonPlayerViewController {
            let parent = presentedViewController.presentingViewController
            presentedViewController.dismiss(animated: false) {
                parent?.present(containerPlayer, animated: false)
                completionHandler(true)
            }
        } else {
            presentedViewController.present(containerPlayer, animated: false) {
                completionHandler(true)
            }
        }
    }

    class PipRecorder {
        static let shared = PipRecorder()
        var playingPipViewController = [CommonPlayerViewController]()
    }
}

/// 永遠不辨識成功，也不阻擋其他 recognizer；只替每次 Menu 按下編號。
private final class PlayerMenuPressObserver: UIGestureRecognizer {
    private(set) var lastMenuPressID: UInt64 = 0
    private(set) var lastMenuPressTimestamp: TimeInterval = .infinity
    private var isMenuPressActive = false
    var onMenuPressBegan: (() -> Void)?

    init() {
        super.init(target: nil, action: nil)
        allowedTouchTypes = []
        allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesBegan(presses, with: event)
        if let press = presses.first(where: { $0.type == .menu }), !isMenuPressActive {
            isMenuPressActive = true
            lastMenuPressTimestamp = press.timestamp
            lastMenuPressID &+= 1
            onMenuPressBegan?()
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesEnded(presses, with: event)
        isMenuPressActive = false
        state = .failed
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        super.pressesCancelled(presses, with: event)
        isMenuPressActive = false
        state = .failed
    }
}

private struct PlayerMenuPlaybackSnapshot {
    weak var player: AVPlayer?
    weak var item: AVPlayerItem?
    let rate: Float
    let menuPressID: UInt64
}
