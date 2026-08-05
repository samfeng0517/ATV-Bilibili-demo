//
//  CDNNodeStore.swift
//  BilibiliLive
//

import Foundation

struct CDNNode: Codable, Hashable, Identifiable {
    enum Source: String, Codable {
        case builtIn
        case manual
        case github
    }

    let id: String
    var name: String
    var host: String
    let source: Source

    init(id: String = UUID().uuidString, name: String, host: String, source: Source) {
        self.id = id
        self.name = name
        self.host = host
        self.source = source
    }
}

enum CDNSelection: String {
    case automatic
    case original
}

enum CDNNodeStore {
    static let defaultListURL = "https://raw.githubusercontent.com/samfeng0517/ATV-Bilibili-demo/main/cdn-list.json"

    static let builtInNode = CDNNode(
        id: "builtin.cn-jxnc-cmcc-bcache-06",
        name: "江西移動（內建）",
        host: "cn-jxnc-cmcc-bcache-06.bilivideo.com",
        source: .builtIn
    )

    static var allNodes: [CDNNode] {
        deduplicated([builtInNode] + Settings.cdnManualNodes + Settings.cdnRemoteNodes)
    }

    static var selectionDescription: String {
        switch Settings.cdnSelection {
        case CDNSelection.automatic.rawValue:
            return "自動選擇（\(allNodes.count) 個）"
        case CDNSelection.original.rawValue:
            return "僅使用 Bilibili 原始節點"
        default:
            return allNodes.first(where: { $0.id == Settings.cdnSelection })?.name ?? "自動選擇"
        }
    }

    /// 回傳應注入到原始 DASH URL 前方的 hostname 順序。
    /// 固定節點模式只注入所選節點；自動模式則提供全部節點給既有的實測選速流程。
    static var candidateHosts: [String] {
        switch Settings.cdnSelection {
        case CDNSelection.original.rawValue:
            return []
        case CDNSelection.automatic.rawValue:
            return allNodes.map(\.host)
        default:
            guard let selected = allNodes.first(where: { $0.id == Settings.cdnSelection }) else {
                return allNodes.map(\.host)
            }
            return [selected.host]
        }
    }

    /// 固定節點模式的首選 host。自動或僅原始節點模式回傳 nil。
    static var fixedSelectedHost: String? {
        guard Settings.cdnSelection != CDNSelection.automatic.rawValue,
              Settings.cdnSelection != CDNSelection.original.rawValue
        else {
            return nil
        }
        return allNodes.first(where: { $0.id == Settings.cdnSelection })?.host
    }

    static func addManualNode(name: String, host input: String) throws {
        let host = try normalizedHost(input)
        guard !allNodes.contains(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }) else {
            throw CDNNodeError.duplicateHost
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.cdnManualNodes.append(CDNNode(
            name: trimmedName.isEmpty ? host : trimmedName,
            host: host,
            source: .manual
        ))
    }

    static func updateManualNode(id: String, name: String, host input: String) throws {
        guard let index = Settings.cdnManualNodes.firstIndex(where: { $0.id == id }) else {
            throw CDNNodeError.nodeNotFound
        }
        let host = try normalizedHost(input)
        guard !allNodes.contains(where: {
            $0.id != id && $0.host.caseInsensitiveCompare(host) == .orderedSame
        }) else {
            throw CDNNodeError.duplicateHost
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.cdnManualNodes[index].name = trimmedName.isEmpty ? host : trimmedName
        Settings.cdnManualNodes[index].host = host
    }

    static func removeManualNode(id: String) {
        Settings.cdnManualNodes.removeAll(where: { $0.id == id })
        if Settings.cdnSelection == id {
            Settings.cdnSelection = CDNSelection.automatic.rawValue
        }
    }

    static func normalizedHost(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { throw CDNNodeError.invalidHost }

        let components: URLComponents?
        if value.contains("://") {
            components = URLComponents(string: value)
        } else {
            components = URLComponents(string: "https://\(value)")
        }

        guard let components,
              let host = components.host,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil,
              isValidHostName(host)
        else {
            throw CDNNodeError.invalidHost
        }
        return host
    }

    private static func isValidHostName(_ host: String) -> Bool {
        guard host.count <= 253, host.contains(".") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty,
                  label.count <= 63,
                  label.first != "-",
                  label.last != "-"
            else {
                return false
            }
            return label.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    static func deduplicated(_ nodes: [CDNNode]) -> [CDNNode] {
        var hosts = Set<String>()
        return nodes.filter { node in
            guard let host = try? normalizedHost(node.host) else { return false }
            return hosts.insert(host).inserted
        }
    }
}

enum CDNNodeError: LocalizedError {
    case invalidHost
    case duplicateHost
    case nodeNotFound
    case invalidListURL
    case invalidResponse
    case listTooLarge
    case emptyList

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "請輸入有效的 CDN hostname，不要包含路徑、參數或連接埠。"
        case .duplicateHost:
            return "這個 CDN 節點已存在。"
        case .nodeNotFound:
            return "找不到這個手動節點。"
        case .invalidListURL:
            return "請輸入有效的 GitHub 或 raw.githubusercontent.com HTTPS 網址。"
        case .invalidResponse:
            return "GitHub 回傳了無效的節點清單。"
        case .listTooLarge:
            return "節點清單超過 1 MB，已拒絕匯入。"
        case .emptyList:
            return "清單內沒有有效的 CDN 節點。"
        }
    }
}

actor CDNListUpdater {
    static let shared = CDNListUpdater()
    static let didUpdateNotification = Notification.Name("CDNListUpdater.didUpdate")

    private struct ListDocument: Decodable {
        let nodes: [ListNode]
    }

    private struct ListNode: Decodable {
        let name: String?
        let host: String
    }

    private let updateInterval: TimeInterval = 24 * 60 * 60
    private let maximumNodeCount = 50
    private var activeUpdate: Task<Int, Error>?

    func updateIfNeeded() async {
        guard Settings.cdnAutoUpdate,
              Date().timeIntervalSince(Settings.cdnLastUpdate) >= updateInterval
        else {
            return
        }
        do {
            _ = try await updateNow()
        } catch {
            Logger.warn("[CustomCDN] GitHub CDN list auto update failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func updateNow() async throws -> Int {
        if let activeUpdate {
            return try await activeUpdate.value
        }
        let task = Task { try await performUpdate() }
        activeUpdate = task
        do {
            let count = try await task.value
            activeUpdate = nil
            return count
        } catch {
            activeUpdate = nil
            throw error
        }
    }

    private func performUpdate() async throws -> Int {
        let url = try validatedListURL(Settings.cdnListURL)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Keys.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            throw CDNNodeError.invalidResponse
        }
        guard data.count <= 1_048_576 else { throw CDNNodeError.listTooLarge }

        let decodedNodes = try decodeNodes(from: data)
        var seenHosts = Set(([CDNNodeStore.builtInNode] + Settings.cdnManualNodes).map(\.host))
        var nodes = [CDNNode]()
        var containsValidHost = false
        for item in decodedNodes {
            guard nodes.count < maximumNodeCount else { break }
            guard let host = try? CDNNodeStore.normalizedHost(item.host) else { continue }
            containsValidHost = true
            guard seenHosts.insert(host).inserted else { continue }
            let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = name.flatMap { $0.isEmpty ? nil : $0 } ?? host
            nodes.append(CDNNode(
                id: "github.\(host)",
                name: displayName,
                host: host,
                source: .github
            ))
        }
        guard containsValidHost else { throw CDNNodeError.emptyList }

        Settings.cdnRemoteNodes = nodes
        let nodeIDs = Set(nodes.map(\.id))
        if Settings.cdnSelection.hasPrefix("github."), !nodeIDs.contains(Settings.cdnSelection) {
            Settings.cdnSelection = CDNSelection.automatic.rawValue
        }
        Settings.cdnLastUpdate = Date()
        Logger.info("[CustomCDN] updated \(nodes.count) CDN nodes from GitHub")
        await MainActor.run {
            NotificationCenter.default.post(name: Self.didUpdateNotification, object: nil)
        }
        return nodes.count
    }

    private func validatedListURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "github.com" || host == "raw.githubusercontent.com"
        else {
            throw CDNNodeError.invalidListURL
        }
        if host == "github.com" {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 5, parts[2] == "blob" {
                var rawComponents = URLComponents()
                rawComponents.scheme = "https"
                rawComponents.host = "raw.githubusercontent.com"
                rawComponents.path = "/" + ([parts[0], parts[1]] + Array(parts.dropFirst(3))).joined(separator: "/")
                guard let rawURL = rawComponents.url else { throw CDNNodeError.invalidListURL }
                return rawURL
            }
        }
        return url
    }

    private func decodeNodes(from data: Data) throws -> [ListNode] {
        let decoder = JSONDecoder()
        if let document = try? decoder.decode(ListDocument.self, from: data) {
            return document.nodes
        }
        if let nodes = try? decoder.decode([ListNode].self, from: data) {
            return nodes
        }
        if let hosts = try? decoder.decode([String].self, from: data) {
            return hosts.map { ListNode(name: nil, host: $0) }
        }
        throw CDNNodeError.invalidResponse
    }
}
