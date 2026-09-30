//
//  PlayerMediaWarmup.swift
//  BilibiliLive
//
//  Created by OpenAI on 2026/4/4.
//

import AVFoundation
import Foundation

final class PreparedPlayerMedia: @unchecked Sendable {
    let asset: AVURLAsset
    let delegate: BilibiliVideoResourceLoaderDelegate

    init(asset: AVURLAsset, delegate: BilibiliVideoResourceLoaderDelegate) {
        self.asset = asset
        self.delegate = delegate
    }
}

enum PlayerMediaFactory {
    static func primaryCDNCandidates(from info: VideoPlayURLInfo,
                                     qualitySelection: BVideoQualitySelection) -> [String]
    {
        let videos = BVideoUrlUtils.selectingVideos(from: info.dash.video, selection: qualitySelection)
        guard let primary = videos.max(by: { $0.bandwidth < $1.bandwidth }) else { return [] }
        let urls = primary.playableURLs
        // 自訂清單再長，原始節點也要參與第一批初篩。
        let ordered = Array(urls.prefix(2)) + primary.originalPlayableURLs + Array(urls.dropFirst(2))
        var seen = Set<String>()
        return ordered.filter { url in
            guard let host = URLComponents(string: url)?.host else { return false }
            return seen.insert(host).inserted
        }
    }

    static func audioBandwidth(from info: VideoPlayURLInfo) -> Int {
        var audios = info.dash.audio ?? []
        if Settings.losslessAudio {
            audios += info.dash.dolby?.audio ?? []
            if let flac = info.dash.flac?.audio { audios.append(flac) }
        }
        return audios.map(\.bandwidth).max() ?? 0
    }

    static func requiredThroughputMbps(from info: VideoPlayURLInfo,
                                       qualitySelection: BVideoQualitySelection,
                                       playbackRate: Double) -> Double
    {
        let video = BVideoUrlUtils.selectingVideos(from: info.dash.video, selection: qualitySelection)
            .map(\.bandwidth).max() ?? 0
        return Double(video + audioBandwidth(from: info)) * playbackRate * 1.5 / 1_000_000
    }

    static func prepare(aid: Int,
                        urlInfo: VideoPlayURLInfo,
                        playerInfo: PlayerInfo?,
                        qualitySelection: BVideoQualitySelection = .settingsDefault,
                        preferredHost: String? = nil) async throws -> PreparedPlayerMedia
    {
        let playURL = URL(string: BilibiliVideoResourceLoaderDelegate.URLs.play)!
        let headers: [String: String] = [
            "User-Agent": Keys.userAgent,
            "Referer": Keys.referer(for: aid),
        ]
        let asset = AVURLAsset(url: playURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let delegate = BilibiliVideoResourceLoaderDelegate()
        delegate.setBilibili(info: urlInfo,
                             subtitles: playerInfo?.subtitle?.subtitles ?? [],
                             aid: aid,
                             qualitySelection: qualitySelection,
                             preferredHost: preferredHost)
        asset.resourceLoader.setDelegate(delegate, queue: DispatchQueue(label: "loader.\(aid).\(UUID().uuidString)"))
        try Task.checkCancellation()
        let playable = try await asset.load(.isPlayable)
        try Task.checkCancellation()
        guard playable else {
            throw "加载资源失败"
        }
        try await withTaskCancellationHandler {
            await delegate.prewarmPrimaryVideoIndex()
            try Task.checkCancellation()
        } onCancel: {
            delegate.cancelPendingIndexLoads()
        }
        return PreparedPlayerMedia(asset: asset, delegate: delegate)
    }
}

actor PlayerMediaWarmupManager {
    private struct InFlightEntry {
        let token: UUID
        let task: Task<PreparedPlayerMedia, Error>
    }

    private let maxPreparedEntries = 4
    private let playContextCache: PlayContextCache
    private var prepared = [String: PreparedPlayerMedia]()
    private var inFlight = [String: InFlightEntry]()
    private var accessOrder = [String]()
    private var cancellationGeneration = 0

    init(playContextCache: PlayContextCache) {
        self.playContextCache = playContextCache
    }

    func preload(playInfo: PlayInfo) async {
        guard let resolved = try? await PlayInfoResolver.resolve(playInfo),
              let snapshot = try? await playContextCache.context(for: resolved, mode: .regular),
              !Task.isCancelled
        else { return }
        let info = snapshot.videoPlayURLInfo
        let host = await CDNDiagnostics.cachedHost(
            urls: PlayerMediaFactory.primaryCDNCandidates(from: info, qualitySelection: .settingsDefault),
            requiredMbps: PlayerMediaFactory.requiredThroughputMbps(from: info,
                                                                    qualitySelection: .settingsDefault,
                                                                    playbackRate: Double(Settings.mediaPlayerSpeed.value))
        )
        guard let host, !Task.isCancelled else { return }
        _ = try? await preparedMedia(for: resolved, preferredHost: host)
    }

    func preparedMedia(for playInfo: PlayInfo, preferredHost: String) async throws -> PreparedPlayerMedia {
        let generation = cancellationGeneration
        let resolvedPlayInfo = try await PlayInfoResolver.resolve(playInfo)
        try Task.checkCancellation()
        guard cancellationGeneration == generation else { throw CancellationError() }
        let key = "\(resolvedPlayInfo.sequenceKey)::\(preferredHost)::\(BVideoQualitySelection.settingsDefault)"
        if let cached = prepared[key], cached.delegate.prewarmedVideoHost == preferredHost {
            touch(key)
            return cached
        }
        // 暖機期間若 SIDX 已回退到別的 host，不可冒用目前已驗證節點的資源。
        prepared[key] = nil
        if let entry = inFlight[key] {
            let media = try await resolve(entry, for: key)
            if media.delegate.prewarmedVideoHost == preferredHost { return media }
            prepared[key] = nil
        }

        let token = UUID()
        let task = Task<PreparedPlayerMedia, Error> {
            try Task.checkCancellation()
            let snapshot = try await playContextCache.context(for: resolvedPlayInfo, mode: .regular)
            try Task.checkCancellation()
            return try await PlayerMediaFactory.prepare(
                aid: resolvedPlayInfo.aid,
                urlInfo: snapshot.videoPlayURLInfo,
                playerInfo: snapshot.playerInfo,
                preferredHost: preferredHost
            )
        }

        let entry = InFlightEntry(token: token, task: task)
        inFlight[key] = entry
        return try await resolve(entry, for: key)
    }

    private func resolve(_ entry: InFlightEntry, for key: String) async throws -> PreparedPlayerMedia {
        do {
            let media = try await entry.task.value
            if let cached = prepared[key] {
                touch(key)
                return cached
            }
            guard inFlight[key]?.token == entry.token else {
                throw CancellationError()
            }
            inFlight[key] = nil
            prepared[key] = media
            touch(key)
            trimToCapacity()
            return media
        } catch {
            if inFlight[key]?.token == entry.token {
                inFlight[key] = nil
            }
            throw error
        }
    }

    func cancelAll() {
        cancellationGeneration += 1
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        prepared.removeAll()
        accessOrder.removeAll()
    }

    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func trimToCapacity() {
        while prepared.count > maxPreparedEntries, let key = accessOrder.first {
            accessOrder.removeFirst()
            prepared[key] = nil
        }
    }
}
