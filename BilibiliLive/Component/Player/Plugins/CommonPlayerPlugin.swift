//
//  CommonPlayerPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/25.
//

import AVKit
import UIKit

protocol CommonPlayerPlugin: NSObject {
    func addViewToPlayerOverlay(container: UIView)
    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement]

    func playerDidLoad(playerVC: AVPlayerViewController)
    func playerDidDismiss(playerVC: AVPlayerViewController)
    func playerWillCleanUp(playerVC: AVPlayerViewController)
    func playerDidChange(player: AVPlayer)
    func playerItemDidChange(playerItem: AVPlayerItem)

    /// 接管 ready 後的起播流程，例如先恢復播放進度再播放。
    var handlesPlaybackStart: Bool { get }
    func playerWillStart(player: AVPlayer)
    func playerDidStart(player: AVPlayer)
    func playerDidPause(player: AVPlayer)
    func playerDidEnd(player: AVPlayer)
    func playerDidStall(player: AVPlayer)
    func playerDidFail(player: AVPlayer)
    func playerDidCleanUp(player: AVPlayer)
}

extension CommonPlayerPlugin {
    func addViewToPlayerOverlay(container: UIView) {}
    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] { return [] }

    var handlesPlaybackStart: Bool { false }
    func playerWillStart(player: AVPlayer) {}
    func playerDidStart(player: AVPlayer) {}
    func playerDidPause(player: AVPlayer) {}
    func playerDidEnd(player: AVPlayer) {}
    func playerDidStall(player: AVPlayer) {}
    func playerDidFail(player: AVPlayer) {}
    func playerDidCleanUp(player: AVPlayer) {}

    func playerDidLoad(playerVC: AVPlayerViewController) {}
    func playerDidDismiss(playerVC: AVPlayerViewController) {}
    func playerWillCleanUp(playerVC: AVPlayerViewController) {}
    func playerDidChange(player: AVPlayer) {}
    func playerItemDidChange(playerItem: AVPlayerItem) {}
}
