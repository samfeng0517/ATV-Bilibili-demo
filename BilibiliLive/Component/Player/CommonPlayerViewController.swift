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
    private var isEnd = false
    private var isRestoringFromPip = false
    var showsPlaybackControls = true
    var allowsPictureInPicturePlayback = true

    deinit {
        cleanUpPlayerOnExit(force: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(playerVC)
        view.addSubview(playerVC.view)
        playerVC.didMove(toParent: self)
        playerVC.view.snp.makeConstraints { $0.edges.equalToSuperview() }
        playerVC.showsPlaybackControls = showsPlaybackControls
        playerVC.allowsPictureInPicturePlayback = allowsPictureInPicturePlayback
        // 保留 AVKit 原生快轉、倒轉與連續操作的行為。
        playerVC.delegate = self

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
        activePlugins.forEach { $0.playerDidDismiss(playerVC: playerVC) }
        cleanUpPlayerOnExit()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        return [playerVC.view]
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
}

extension CommonPlayerViewController {
    private func playerDidChange(player: AVPlayer?) {
        cleanUpSubtitleSelection()
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
            self.selectedSubtitleOption = item.currentMediaSelection.selectedMediaOption(in: group)
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
        guard subtitleSelectionObserver != nil,
              let group = subtitleSelectionGroup,
              group == mediaSelectionGroup
        else { return }
        // 只有字幕選單的明確操作更新偏好；系統暫時選取／取消字幕不改寫它。
        selectedSubtitleOption = mediaSelectionOption
    }

    @objc func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
        if let presentedViewController = UIViewController.topMostViewController() as? CommonPlayerViewController,
           presentedViewController.playerVC == playerViewController
        {
            dismiss(animated: true)
            return false
        }
        return false
    }

    @objc func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_: AVPlayerViewController) -> Bool {
        return true
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
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
