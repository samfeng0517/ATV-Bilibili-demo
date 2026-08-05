//
//  BVideoPlayPlugin.swift
//  BilibiliLive
//
//  Created by yicheng on 2024/5/24.
//

import AVKit
import UIKit

class BVideoPlayPlugin: NSObject, CommonPlayerPlugin {
    private weak var playerVC: AVPlayerViewController?
    private var playerDelegate: BilibiliVideoResourceLoaderDelegate?
    private let playData: PlayerDetailData
    private var currentQualityId: Int?
    private var currentPlaybackTime: Double = 0
    // 記錄最近一次實際使用的畫質模式，切換 CDN host 時原樣復用。
    private var currentQualitySelection = BVideoQualitySelection.settingsDefault

    private var networkLogTimer: Timer?
    private var lastStalls = 0
    private var lastDroppedFrames = 0
    private var cdnProbeReport = ""
    private var isProbingCDN = false
    private var lastKnownPlaybackRate = max(1, Double(Settings.mediaPlayerSpeed.value))

    // 运行时 CDN 健康检测：根据真实卡顿或 AVPlayer 的 keep-up 缓冲风险换 host，
    // 不单独用 observed/indicated 比特率比（indicated 常是峰值，低一些仍可能流畅）。
    private var stallUnhealthyStreak = 0
    private var isEvaluatingHostSwitch = false
    private var lastHostSwitchAt: Date?
    /// 连续几次处于卡顿/等待缓冲才触发，避免单次抖动
    private let stallTriggerCount = 2
    /// 换完 host 后的冷静期，避免连续误触发
    private let hostSwitchCooldown: TimeInterval = 30
    private let networkLogInterval: TimeInterval = 5
    /// preferredForwardBufferDuration 是媒体时间；倍速播放时必须按速率放大，
    /// 才能维持相同的实际可播放秒数。上限 30 秒，避免恢复到 60 秒造成 seek 请求风暴。
    private let baseForwardBufferDuration: TimeInterval = 15
    private let maximumForwardBufferDuration: TimeInterval = 30
    /// CDN 实测吞吐至少要高于「平均码率 × 播放速度」一些，才能吸收分片峰值与网络抖动。
    private let throughputHeadroom = 1.25

    init(detailData: PlayerDetailData) {
        playData = detailData
        currentQualityId = playData.videoPlayURLInfo.quality
    }

    deinit {
        networkLogTimer?.invalidate()
    }

    /// 供 DebugPlugin 浮层显示的网络诊断信息
    var networkDebugInfo: String {
        var lines = [String]()
        if let host = playerDelegate?.currentSegmentHost {
            lines.append("segment host: \(host)")
        }
        if !cdnProbeReport.isEmpty {
            lines.append(cdnProbeReport)
        }
        return lines.joined(separator: "\n")
    }

    func playerDidLoad(playerVC: AVPlayerViewController) {
        self.playerVC = playerVC
        playerVC.player = nil
        playerVC.appliesPreferredDisplayCriteriaAutomatically = Settings.contentMatch
        Task {
            try? await playmedia(urlInfo: playData.videoPlayURLInfo, playerInfo: playData.playerInfo, qualitySelection: currentQualitySelection)
        }
    }

    func playerWillStart(player: AVPlayer) {
        if let playerStartPos = playData.playerStartPos {
            player.seek(to: CMTime(seconds: Double(playerStartPos), preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    func playerDidStart(player: AVPlayer) {
        updateForwardBuffer(for: player)
        startNetworkLogging()
    }

    func playerDidCleanUp(player _: AVPlayer) {
        stopNetworkLogging()
    }

    func addMenuItems(current: inout [UIMenuElement]) -> [UIMenuElement] {
        // 挂进「播放设置」，与 Debug 并列（依赖 SpeedChangerPlugin 先创建 setting 菜单）
        let action = UIAction(title: isProbingCDN ? "CDN 测速中…" : "CDN 测速",
                              image: UIImage(systemName: "speedometer"))
        { [weak self] _ in
            self?.probeCDN()
        }
        if let setting = current.compactMap({ $0 as? UIMenu })
            .first(where: { $0.identifier == UIMenu.Identifier(rawValue: "setting") }),
            let index = current.firstIndex(of: setting)
        {
            current[index] = setting.replacingChildren(setting.children + [action])
            return []
        }
        return []
    }

    private func probeCDN() {
        guard !isProbingCDN else { return }
        let candidates = playerDelegate?.cdnCandidates ?? []
        guard !candidates.isEmpty else {
            cdnProbeReport = "无候选 CDN"
            return
        }
        let currentHost = playerDelegate?.currentSegmentHost
        isProbingCDN = true
        cdnProbeReport = "CDN 测速中…"
        Task { @MainActor [weak self] in
            let report = await CDNDiagnostics.run(urls: candidates, currentHost: currentHost)
            self?.cdnProbeReport = report
            self?.isProbingCDN = false
        }
    }

    private func startNetworkLogging() {
        guard networkLogTimer == nil else { return }
        networkLogTimer = Timer.scheduledTimer(withTimeInterval: networkLogInterval, repeats: true) { [weak self] _ in
            self?.logNetworkStatus()
        }
    }

    private func stopNetworkLogging() {
        networkLogTimer?.invalidate()
        networkLogTimer = nil
    }

    private func logNetworkStatus() {
        guard let player = playerVC?.player,
              let item = player.currentItem,
              let event = item.accessLog()?.events.last
        else { return }
        // event.uri 是内部 variant playlist 的地址（我们用的是自定义 atv://dash/N scheme），
        // 解析出来的 host 恒为 "dash"，跟实际连的 CDN 无关；真实 host 记录在 playerDelegate 里。
        let host = playerDelegate?.currentSegmentHost ?? "-"
        let observedBps = event.observedBitrate
        let indicatedBps = event.indicatedBitrate
        let effectiveIndicated = effectiveIndicatedBitrate(from: indicatedBps)
        let observed = String(format: "%.1f", observedBps / 1_000_000)
        let indicated = String(format: "%.1f", indicatedBps / 1_000_000)
        let effective = String(format: "%.1f", effectiveIndicated / 1_000_000)
        let stalls = event.numberOfStalls
        let dropped = event.numberOfDroppedVideoFrames
        let tcs = player.timeControlStatus
        let waiting = player.reasonForWaitingToPlay?.rawValue ?? "-"
        let keepUp = item.isPlaybackLikelyToKeepUp
        let buffered = bufferedSeconds(of: item)
        let playbackRate = effectivePlaybackRate(for: player)
        let requiredMbps = requiredThroughputMbps(playbackRate: playbackRate)
        let stallDelta = stalls - lastStalls
        Logger.info("playback host \(host) rate \(String(format: "%.2f", playbackRate))x required \(String(format: "%.1f", requiredMbps))Mbps observed \(observed)Mbps indicated \(indicated)Mbps effective \(effective)Mbps stalls \(stalls)(+\(stallDelta)) dropped \(dropped)(+\(dropped - lastDroppedFrames)) serverChanges \(event.numberOfServerAddressChanges) tcs \(tcs.rawValue) wait \(waiting) keepUp \(keepUp) buffered \(String(format: "%.1f", buffered))s")
        lastStalls = stalls
        lastDroppedFrames = dropped

        checkStallHealth(stallDelta: stallDelta,
                         buffered: buffered,
                         isLikelyToKeepUp: keepUp,
                         playbackRate: playbackRate,
                         currentHost: host)
    }

    /// 用户明确暂停（.paused）。卡缓冲/断网时是 .waitingToPlayAtSpecifiedRate，仍应做健康检测。
    private var isUserPaused: Bool {
        playerVC?.player?.timeControlStatus == .paused
    }

    private var isWaitingToPlay: Bool {
        playerVC?.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    /// access log 的 indicated 在起播/loading 时常为 0 或负值；日志里的 effective 用流声明平均带宽兜底。
    private func effectiveIndicatedBitrate(from accessLogIndicated: Double) -> Double {
        if accessLogIndicated > 0 { return accessLogIndicated }
        guard let declared = playerDelegate?.primaryVideoBandwidth, declared > 0 else { return 0 }
        return Double(declared)
    }

    /// AVPlayer.rate 是目前選擇的播放速度；等待緩衝時沿用最後的非零速率，
    /// 避免將倍速吞吐需求誤算成 0 或退回預設值。
    private func effectivePlaybackRate(for player: AVPlayer) -> Double {
        if player.rate > 0 {
            lastKnownPlaybackRate = Double(player.rate)
        }
        return lastKnownPlaybackRate
    }

    private func requiredThroughputMbps(playbackRate: Double) -> Double {
        let averageBitrate = Double(playerDelegate?.primaryVideoBandwidth ?? 0)
        return averageBitrate * playbackRate * throughputHeadroom / 1_000_000
    }

    private func forwardBufferDuration(playbackRate: Double) -> TimeInterval {
        min(maximumForwardBufferDuration,
            baseForwardBufferDuration * max(1, playbackRate))
    }

    private func updateForwardBuffer(for player: AVPlayer) {
        guard let item = player.currentItem else { return }
        let playbackRate = effectivePlaybackRate(for: player)
        let duration = forwardBufferDuration(playbackRate: playbackRate)
        guard item.preferredForwardBufferDuration != duration else { return }
        item.preferredForwardBufferDuration = duration
        Logger.info("[buffer] rate \(String(format: "%.2f", playbackRate))x, forward buffer \(String(format: "%.0f", duration))s media time")
    }

    private func bufferedSeconds(of item: AVPlayerItem) -> Double {
        let current = item.currentTime().seconds
        guard current.isFinite else { return 0 }

        // seek 后 loadedTimeRanges 可能同时保留旧位置与新位置，不能假设第一个 range
        // 就是当前播放区间。
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = start + range.duration.seconds
            guard start.isFinite, end.isFinite else { continue }
            if current >= start, current <= end {
                return max(0, end - current)
            }
        }
        return 0
    }

    /// 根据真实卡顿或即将耗尽的缓冲触发换源；播放流畅时仅 observed < indicated
    /// 不触发——indicated 常是峰值，低一些完全正常。
    private func checkStallHealth(stallDelta: Int,
                                  buffered: Double,
                                  isLikelyToKeepUp: Bool,
                                  playbackRate: Double,
                                  currentHost: String)
    {
        guard !isUserPaused, !isEvaluatingHostSwitch else {
            stallUnhealthyStreak = 0
            return
        }
        if let lastSwitch = lastHostSwitchAt, Date().timeIntervalSince(lastSwitch) < hostSwitchCooldown {
            return
        }

        // loadedTimeRanges 以媒体秒计。倍速越高，同样的媒体缓冲可支撑的墙钟时间越短；
        // likelyToKeepUp 已转差且缓冲不足时提前处理，不必等到真正停住才开始测速。
        let lowBufferThreshold = 10 * playbackRate
        let isRunningOutOfBuffer = !isLikelyToKeepUp && buffered < lowBufferThreshold
        let unhealthy = isWaitingToPlay || stallDelta > 0 || isRunningOutOfBuffer
        if unhealthy {
            stallUnhealthyStreak += 1
        } else {
            stallUnhealthyStreak = 0
            return
        }
        // access log 已確認新增 stall 時立即處理；waiting／keep-up 短暫抖動則仍需連續兩次，
        // 避免使用者 seek 或剛起播時誤切 CDN。
        let requiredStreak = stallDelta > 0 ? 1 : stallTriggerCount
        guard stallUnhealthyStreak >= requiredStreak else { return }
        stallUnhealthyStreak = 0

        let requiredMbps = requiredThroughputMbps(playbackRate: playbackRate)
        Logger.info("[cdn] 检测到缓冲风险 (rate=\(String(format: "%.2f", playbackRate))x, required=\(String(format: "%.1f", requiredMbps))Mbps, waiting=\(isWaitingToPlay), keepUp=\(isLikelyToKeepUp), stallDelta=\(stallDelta), buffered \(String(format: "%.1f", buffered))s)，重新测速")
        Task { @MainActor [weak self] in
            await self?.evaluateHostSwitch(currentHost: currentHost, requiredMbps: requiredMbps)
        }
    }

    @MainActor
    private func evaluateHostSwitch(currentHost: String, requiredMbps: Double) async {
        guard !isEvaluatingHostSwitch else { return }
        guard !isUserPaused else { return }
        let candidates = playerDelegate?.cdnCandidates ?? []
        guard candidates.count > 1 else { return }
        isEvaluatingHostSwitch = true
        defer { isEvaluatingHostSwitch = false }

        Logger.info("[cdn] \(currentHost) 因卡顿重新测速 \(candidates.count) 个候选")
        let results = await CDNDiagnostics.probeAll(urls: candidates)
        // 测速是异步的，期间用户可能已手动暂停；换源会重建 AVPlayer，必须取消
        guard !isUserPaused else {
            Logger.info("[cdn] 用户已暂停，取消 host 切换")
            return
        }
        let ranked = results.filter { $0.mbps != nil }.sorted { ($0.mbps ?? -1) > ($1.mbps ?? -1) }
        guard !ranked.isEmpty else {
            Logger.info("[cdn] 候选测速全部失败，保持 \(currentHost)")
            return
        }

        // 优先更快的非当前节点；若短测速仍显示当前最快，则取第二名做强制尝试
        let alternate = ranked.first(where: { $0.host != currentHost })
        guard let target = alternate, let targetMbps = target.mbps else {
            Logger.info("[cdn] 没有其他可用候选，保持 \(currentHost)")
            return
        }
        let currentMbps = ranked.first(where: { $0.host == currentHost })?.mbps
        let reason: String
        if requiredMbps > 0, targetMbps >= requiredMbps,
           currentMbps.map({ $0 < requiredMbps }) ?? true
        {
            reason = "满足倍速吞吐需求"
        } else if let currentMbps, targetMbps > currentMbps * 1.3 {
            reason = "测速明显更快"
        } else if let currentMbps, targetMbps >= currentMbps * 0.7 {
            // 短测速乐观且接近时，当前节点已真实卡顿，强制换一个试试
            reason = "测速接近但已卡顿，强制尝试"
        } else if currentMbps == nil {
            reason = "当前节点测速失败"
        } else {
            Logger.info("[cdn] 备选 \(target.host) (\(String(format: "%.1f", targetMbps))Mbps) 明显慢于当前 \(currentHost) (\(String(format: "%.1f", currentMbps!))Mbps)，保持")
            return
        }

        lastHostSwitchAt = Date()
        Logger.info("[cdn] 切换 host: \(currentHost) -> \(target.host) (实测\(String(format: "%.1f", targetMbps))Mbps, 需求\(String(format: "%.1f", requiredMbps))Mbps, \(reason))")
        await switchHost(to: target.host)
    }

    @MainActor
    private func switchHost(to host: String) async {
        guard let player = playerVC?.player else { return }
        // 必须在换源前记下播放意图：新 AVPlayer 默认就是 .paused，换源后再读 isUserPaused 会误判成用户暂停
        let shouldResume = !isUserPaused
        guard shouldResume else {
            Logger.info("[cdn] 用户已暂停，取消 host 切换")
            return
        }
        let currentTime = player.currentTime().seconds
        guard currentTime > 0 else { return }
        currentPlaybackTime = currentTime

        // 关掉 readyToPlay 自动 play，改由下面按 shouldResume 显式 play；异步恢复默认，避开尚未送达的 status KVO
        let commonVC = playerVC?.parent as? CommonPlayerViewController
        commonVC?.autoPlayWhenReady = false
        defer {
            DispatchQueue.main.async {
                commonVC?.autoPlayWhenReady = true
            }
        }

        do {
            try await playmedia(urlInfo: playData.videoPlayURLInfo, playerInfo: playData.playerInfo, qualitySelection: currentQualitySelection, preferredHost: host, isQualitySwitch: true)
            if let newPlayer = playerVC?.player {
                await newPlayer.seek(to: CMTime(seconds: currentPlaybackTime, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
                if shouldResume {
                    newPlayer.play()
                } else {
                    newPlayer.pause()
                }
            }
        } catch {
            Logger.warn("[cdn] 切换 host 失败: \(error)")
        }
    }

    func playerDidDismiss(playerVC: AVPlayerViewController) {
        guard let currentTime = playerVC.player?.currentTime().seconds, currentTime > 0 else { return }
        WebRequest.reportWatchHistory(aid: playData.aid, cid: playData.cid, currentTime: Int(currentTime), epid: playData.epid, seasonId: playData.seasonId, subType: playData.subType)
    }

    /// 与资源加载器选主视频流的逻辑对齐，取出该流各 CDN host 的代表 URL，供起播轻量测速。
    private func primaryCDNCandidates(from info: VideoPlayURLInfo, qualitySelection: BVideoQualitySelection) -> [String] {
        var videos = BVideoUrlUtils.selectingVideos(from: info.dash.video, selection: qualitySelection)
        videos.sort { $0.bandwidth > $1.bandwidth }
        guard let primary = videos.first else { return [] }
        var seenHosts = Set<String>()
        return primary.playableURLs.filter { url in
            guard let host = URLComponents(string: url)?.host else { return false }
            return seenHosts.insert(host).inserted
        }
    }

    @MainActor
    private func playmedia(urlInfo: VideoPlayURLInfo, playerInfo: PlayerInfo?, qualitySelection: BVideoQualitySelection, preferredHost: String? = nil, isQualitySwitch: Bool = false) async throws {
        let playURL = URL(string: BilibiliVideoResourceLoaderDelegate.URLs.play)!
        let headers: [String: String] = [
            "User-Agent": Keys.userAgent,
            "Referer": Keys.referer(for: playData.aid),
        ]
        let asset = AVURLAsset(url: playURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        // access log 是按 item 统计的，换流后累计值归零，这里同步重置增量基准
        lastStalls = 0
        lastDroppedFrames = 0
        currentQualitySelection = qualitySelection

        // 起播 / 切画质时做一次轻量测速选 host；运行时已指定 preferredHost 的切换则跳过
        var resolvedHost = preferredHost ?? CDNNodeStore.fixedSelectedHost
        if resolvedHost == nil {
            let candidates = primaryCDNCandidates(from: urlInfo, qualitySelection: qualitySelection)
            if let best = await CDNDiagnostics.pickFastestHost(urls: candidates) {
                resolvedHost = best
                Logger.info("[cdn] 起播选用 host: \(best)")
            }
        }

        playerDelegate = BilibiliVideoResourceLoaderDelegate()
        playerDelegate?.setBilibili(info: urlInfo, subtitles: playerInfo?.subtitle?.subtitles ?? [], aid: playData.aid, qualitySelection: qualitySelection, preferredHost: resolvedHost)

        // 只在初次加载时设置 appliesPreferredDisplayCriteriaAutomatically，切换画质时跳过
        if !isQualitySwitch {
            if Settings.contentMatchOnlyInHDR {
                if playerDelegate?.isHDR != true {
                    playerVC?.appliesPreferredDisplayCriteriaAutomatically = false
                }
            }
        }

        asset.resourceLoader.setDelegate(playerDelegate, queue: DispatchQueue(label: "loader"))
        let playable = try await asset.load(.isPlayable)
        if !playable {
            throw "加载资源失败"
        }
        await prepare(toPlay: asset)
    }

    @MainActor
    func switchQuality(to selection: BVideoQualitySelection) async {
        guard let player = playerVC?.player else { return }

        let currentTime = player.currentTime().seconds

        // 保存当前播放位置
        currentPlaybackTime = currentTime.isFinite ? max(0, currentTime) : 0
        currentQualityId = selection.qualityId

        // 重新加载视频，使用新的画质
        do {
            try await playmedia(urlInfo: playData.videoPlayURLInfo, playerInfo: playData.playerInfo, qualitySelection: selection, isQualitySwitch: true)

            // 恢复播放位置并继续播放
            if let newPlayer = playerVC?.player {
                if currentPlaybackTime > 0 {
                    await newPlayer.seek(to: CMTime(seconds: currentPlaybackTime, preferredTimescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                newPlayer.play()
            }
        } catch {
            Logger.warn("[quality] Failed to switch quality: \(error)")
        }
    }

    @MainActor
    func prepare(toPlay asset: AVURLAsset) async {
        let playerItem = AVPlayerItem(asset: asset)

        // 设置 preferredPeakBitRate 为一个很高的值，让 AVPlayer 优先选择高码率流
        // 0 表示无限制，让 AVPlayer 根据网络条件自动选择最高可用码率
        playerItem.preferredPeakBitRate = 0

        // 倍速会更快消耗媒体时间缓冲。依当前设置在 15～30 秒间调整，维持至少约 15 秒
        // 的墙钟缓冲，同时避免原本固定 60 秒在连续 seek 时造成请求风暴。
        playerItem.preferredForwardBufferDuration = forwardBufferDuration(
            playbackRate: lastKnownPlaybackRate
        )

        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        playerVC?.player = nil
        playerVC?.player = player
    }
}
