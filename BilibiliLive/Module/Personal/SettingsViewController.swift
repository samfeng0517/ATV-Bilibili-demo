//
//  SettingsViewController.swift
//  BilibiliLive
//
//  Created by whw on 2022/10/19.
//

import UIKit

class SettingsViewController: UIViewController {
    class SectionModel: Hashable, Equatable {
        let title: String
        let items: [CellModel]

        init(title: String, @ArrayBuilder<CellModel> items: () -> [CellModel]) {
            self.title = title
            self.items = items()
        }

        static func == (lhs: SectionModel, rhs: SectionModel) -> Bool {
            lhs.title == rhs.title && lhs.items == rhs.items
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(title)
            hasher.combine(items)
        }
    }

    class CellModel: Hashable, Equatable {
        let id: String
        let title: String
        let desp: () -> String
        let action: ((@escaping () -> Void) -> Void)?

        var updateAction: (() -> Void)?

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: CellModel, rhs: CellModel) -> Bool {
            lhs.id == rhs.id
        }

        init(id: String? = nil, title: String, desp: @autoclosure @escaping () -> String, action: ((@escaping () -> Void) -> Void)?) {
            self.id = id ?? title
            self.title = title
            self.desp = desp
            self.action = action
        }
    }

    let collectionView: UICollectionView = {
        let layout = UICollectionViewCompositionalLayout { sectionIndex, environment -> NSCollectionLayoutSection? in
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(68))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)

            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(68))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
            group.interItemSpacing = .fixed(10)

            let section = NSCollectionLayoutSection(group: group)
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(44)
            )

            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: "header",
                alignment: .top
            )
            header.pinToVisibleBounds = false
            section.boundarySupplementaryItems = [header]
            section.interGroupSpacing = 10
            return section
        }
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()

    var dataSource: UICollectionViewDiffableDataSource<SectionModel, CellModel>!
    private var isUpdatingCDNList = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(collectionView)
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.snp.makeConstraints { make in
            make.top.right.bottom.equalToSuperview()
            make.left.equalToSuperview().offset(20)
        }

        collectionView.delegate = self
        collectionView.register(SettingsSwitchCell.self, forCellWithReuseIdentifier: String(describing: SettingsSwitchCell.self))
        collectionView.register(SettingsHeaderView.self, forSupplementaryViewOfKind: "header", withReuseIdentifier: "HeaderView")

        configureDataSource()
        setupData()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cdnListDidUpdate),
            name: CDNListUpdater.didUpdateNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        dataSource?.snapshot().itemIdentifiers.forEach { $0.updateAction?() }
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<SectionModel, CellModel>(collectionView: collectionView) { collectionView, indexPath, cellModel -> UICollectionViewCell? in
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: String(describing: SettingsSwitchCell.self), for: indexPath) as! SettingsSwitchCell
            cell.set(with: cellModel)
            return cell
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "HeaderView", for: indexPath) as! SettingsHeaderView
            let title = self?.dataSource.snapshot().sectionIdentifiers[indexPath.section].title ?? UUID().uuidString

            header.label.text = title
            return header
        }
    }

    private func setupData() {
        createSnapshot {
            SectionModel(title: "通用") {
                Toggle(title: "启用投屏", setting: Settings.enableDLNA, onChange: Settings.enableDLNA.toggle()) {
                    _ in
                    BiliBiliUpnpDMR.shared.start()
                }

                Toggle(title: "热门个性化推荐", setting: Settings.requestHotWithoutCookie, onChange: Settings.requestHotWithoutCookie.toggle())
            }

            SectionModel(title: "界面") {
                Navigation(title: "自定义Tab栏", desp: "") { [weak self] in
                    let controller = TabBarCustomizationViewController()
                    self?.present(controller, animated: true)
                }

                Actions(title: "视频每行显示个数", message: "重启app生效",
                        current: Settings.displayStyle.desp,
                        options: FeedDisplayStyle.allCases.filter({ !$0.hideInSetting }),
                        optionString: FeedDisplayStyle.allCases.filter({ !$0.hideInSetting }).map({ $0.desp }))
                {
                    Settings.displayStyle = $0
                }
                Toggle(title: "侧边栏菜单自动切换", setting: Settings.sideMenuAutoSelectChange, onChange: Settings.sideMenuAutoSelectChange.toggle())

                Toggle(title: "不显示详情页直接进入视频",
                       setting: Settings.direatlyEnterVideo,
                       onChange: Settings.direatlyEnterVideo.toggle())

                Actions(title: "视频详情相关推荐加载模式", message: "4k以上需要大会员",
                        current: Settings.showRelatedVideoInCurrentVC ? "页面刷新" : "新页面中打开",
                        options: [true, false],
                        optionString: ["页面刷新", "新页面中打开"])
                {
                    Settings.showRelatedVideoInCurrentVC = $0
                }
            }

            SectionModel(title: "音视频") {
                Actions(title: "使用 CDN 節點", message: "自動模式會讓播放前的既有測速流程從所有節點中擇優。",
                        current: CDNNodeStore.selectionDescription,
                        options: [CDNSelection.automatic.rawValue, CDNSelection.original.rawValue] + CDNNodeStore.allNodes.map(\.id),
                        optionString: ["自動選擇", "僅使用 Bilibili 原始節點"] + CDNNodeStore.allNodes.map(\.name))
                { [weak self] selection in
                    Settings.cdnSelection = selection
                    self?.setupData()
                }

                CustomAction(id: "cdn.manual.add", title: "新增手動 CDN 節點", desp: "輸入名稱與 hostname") { [weak self] in
                    self?.showManualCDNNodeEditor(node: nil)
                }

                for node in Settings.cdnManualNodes {
                    CustomAction(id: "cdn.manual.\(node.id)", title: "手動節點：\(node.name)", desp: node.host) { [weak self] in
                        self?.showManualCDNNodeActions(node)
                    }
                }

                Toggle(title: "CDN 清單自動更新", setting: Settings.cdnAutoUpdate, onChange: Settings.cdnAutoUpdate.toggle()) { [weak self] enabled in
                    self?.setupData()
                    if enabled {
                        self?.updateCDNList()
                    }
                }

                CustomAction(id: "cdn.github.url", title: "CDN 清單網址", desp: Settings.cdnListURL) { [weak self] in
                    self?.showCDNListURLEditor()
                }

                CustomAction(id: "cdn.github.update", title: isUpdatingCDNList ? "正在更新 CDN 清單…" : "立即更新 CDN 清單", desp: self.cdnUpdateDescription) { [weak self] in
                    self?.updateCDNList()
                }

                if !Settings.cdnRemoteNodes.isEmpty {
                    CustomAction(id: "cdn.github.clear", title: "清除已下載 CDN 清單", desp: "共 \(Settings.cdnRemoteNodes.count) 個節點") { [weak self] in
                        self?.confirmClearRemoteCDNNodes()
                    }
                }
                Actions(title: "偏好畫質", message: "影片未提供偏好畫質時，會自動選擇較低一級的最高畫質；自動模式會依網路狀況調整。4K 以上需要大會員。",
                        current: Settings.mediaQuality.desp,
                        options: MediaQualityEnum.allCases,
                        optionString: MediaQualityEnum.allCases.map({ $0.desp }))
                {
                    Settings.mediaQuality = $0
                }
                Actions(title: "默认播放速度", message: "默认设置为1.0",
                        current: Settings.mediaPlayerSpeed.name,
                        options: PlaySpeed.blDefaults,
                        optionString: PlaySpeed.blDefaults.map({ $0.name }))
                {
                    Settings.mediaPlayerSpeed = $0
                }
                if !BVideoUrlUtils.supportsHEVCHardwareDecoding {
                    Toggle(title: "AVC 優先（卡頓時可嘗試）", setting: Settings.preferAvc, onChange: Settings.preferAvc.toggle())
                }
                Toggle(title: "无损音频和杜比全景声", setting: Settings.losslessAudio, onChange: Settings.losslessAudio.toggle())
                Toggle(title: "匹配视频内容", setting: Settings.contentMatch, onChange: Settings.contentMatch.toggle())
                Toggle(title: "仅在HDR视频匹配视频内容", setting: Settings.contentMatchOnlyInHDR, onChange: Settings.contentMatchOnlyInHDR.toggle())
            }

            SectionModel(title: "进度控制") {
                Toggle(title: "从上次退出的位置继续播放", setting: Settings.continuePlay, onChange: Settings.continuePlay.toggle())
                Toggle(title: "自动跳过片头片尾", setting: Settings.autoSkip, onChange: Settings.autoSkip.toggle())
                Toggle(title: "连续播放", setting: Settings.continouslyPlay, onChange: Settings.continouslyPlay.toggle())
                Actions(title: "空降助手广告屏蔽", message: "",
                        current: Settings.enableSponsorBlock.title,
                        options: SponsorBlockType.allCases,
                        optionString: SponsorBlockType.allCases.map({ $0.title }))
                {
                    Settings.enableSponsorBlock = $0
                }
            }

            SectionModel(title: "弹幕") {
                Toggle(title: "用户自定义弹幕屏蔽", setting: Settings.enableDanmuFilter, onChange: Settings.enableDanmuFilter.toggle()) {
                    enable in
                    if enable {
                        Task {
                            let toast = await VideoDanmuFilter.shared.update()
                            let alert = UIAlertController(title: "同步结果", message: toast, preferredStyle: .alert)
                            alert.addAction(.init(title: "Ok", style: .cancel))
                            self.present(alert, animated: true)
                        }
                    }
                }
                Toggle(title: "移除重复弹幕", setting: Settings.enableDanmuRemoveDup, onChange: Settings.enableDanmuRemoveDup.toggle())
                Actions(title: "弹幕大小", message: "默认为36", current: Settings.danmuSize.title, options: DanmuSize.allCases, optionString: DanmuSize.allCases.map({ $0.title })) {
                    Settings.danmuSize = $0
                }
                Actions(title: "弹幕显示区域", message: "设置弹幕显示区域",
                        current: Settings.danmuArea.title,
                        options: DanmuArea.allCases,
                        optionString: DanmuArea.allCases.map({ $0.title }))
                {
                    Settings.danmuArea = $0
                }
                Toggle(title: "智能防档弹幕", setting: Settings.danmuMask, onChange: Settings.danmuMask.toggle())
                Toggle(title: "按需本地运算智能防档弹幕(Exp)", setting: Settings.vnMask, onChange: Settings.vnMask.toggle())

                // 添加弹幕透明度设置
                Actions(title: "弹幕透明度", message: "调整弹幕的透明度",
                        current: Settings.danmuAlpha.title,
                        options: DanmuAlpha.allCases,
                        optionString: DanmuAlpha.allCases.map({ $0.title }))
                { value in
                    Settings.danmuAlpha = value
                }

                // 添加弹幕描边宽度设置
                Actions(title: "弹幕描边宽度", message: "调整弹幕描边的粗细",
                        current: Settings.danmuStrokeWidth.title,
                        options: DanmuStrokeWidth.allCases,
                        optionString: DanmuStrokeWidth.allCases.map({ $0.title }))
                { value in
                    Settings.danmuStrokeWidth = value
                }

                // 添加弹幕描边透明度设置
                Actions(title: "弹幕描边透明度", message: "调整弹幕描边的透明度",
                        current: Settings.danmuStrokeAlpha.title,
                        options: DanmuStrokeAlpha.allCases,
                        optionString: DanmuStrokeAlpha.allCases.map({ $0.title }))
                { value in
                    Settings.danmuStrokeAlpha = value
                }
            }

            SectionModel(title: "港澳台解锁") {
                Toggle(title: "解锁港澳台番剧限制", setting: Settings.areaLimitUnlock, onChange: Settings.areaLimitUnlock.toggle())
                TextField(title: "设置港澳台解析服务器", message: "为了安全考虑建议自建服务器，公共服务器可用性难保证，请多尝试几个。\n公共服务器请参考：http://985.so/mjq9u", current: Settings.areaLimitCustomServer, placeholder: "api.example.com") {
                    Settings.areaLimitCustomServer = $0 ?? ""
                }
            }
        }
    }
}

extension SettingsViewController {
    func CustomAction(id: String,
                      title: String,
                      desp: @autoclosure @escaping () -> String,
                      onSelect: @escaping () -> Void) -> CellModel
    {
        CellModel(id: id, title: title, desp: desp()) { update in
            onSelect()
            update()
        }
    }

    func Toggle(title: String, setting: @autoclosure @escaping () -> Bool,
                onChange: @autoclosure @escaping () -> Void,
                extraAction: ((Bool) -> Void)? = nil) -> CellModel
    {
        return CellModel(title: title, desp: setting() ? "开" : "关") {
            update in
            onChange()
            extraAction?(setting())
            update()
        }
    }

    func Actions<T>(title: String,
                    message: String?,
                    current: @autoclosure @escaping () -> String,
                    options: [T],
                    optionString: [String],
                    onSelect: ((T) -> Void)? = nil) -> CellModel
    {
        return CellModel(title: title, desp: current()) { [weak self] update in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)

            for (idx, string) in optionString.enumerated() {
                let action = UIAlertAction(title: string, style: .default) { _ in
                    onSelect?(options[idx])
                    update()
                }
                alert.addAction(action)
            }
            let cancelAction = UIAlertAction(title: nil, style: .cancel)
            alert.addAction(cancelAction)
            self?.present(alert, animated: true)
        }
    }

    func TextField(title: String,
                   message: String?,
                   current: String,
                   placeholder: String?,
                   isSecureTextEntry: Bool = false,
                   onSubmit: ((String?) -> Void)? = nil) -> CellModel
    {
        return CellModel(title: title, desp: current) { [weak self] update in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addTextField { textField in
                textField.text = current
                textField.keyboardType = .URL
                textField.placeholder = placeholder
                textField.isSecureTextEntry = isSecureTextEntry
            }

            let action = UIAlertAction(title: "确定", style: .default) { _ in
                onSubmit?(alert.textFields![0].text)
                update()
            }
            alert.addAction(action)

            let cancelAction = UIAlertAction(title: nil, style: .cancel)
            alert.addAction(cancelAction)
            self?.present(alert, animated: true)
        }
    }

    func Navigation(title: String,
                    desp: @autoclosure @escaping () -> String,
                    onSelect: (() -> Void)? = nil) -> CellModel
    {
        return CellModel(title: title, desp: desp()) { update in
            onSelect?()
            update()
        }
    }
}

private extension SettingsViewController {
    var cdnUpdateDescription: String {
        if isUpdatingCDNList {
            return "正在從 GitHub 下載"
        }
        guard Settings.cdnLastUpdate.timeIntervalSince1970 > 0 else {
            return "尚未更新"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "上次更新：\(formatter.string(from: Settings.cdnLastUpdate))，\(Settings.cdnRemoteNodes.count) 個節點"
    }

    func showManualCDNNodeActions(_ node: CDNNode) {
        let alert = UIAlertController(title: node.name, message: node.host, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "使用這個節點", style: .default) { [weak self] _ in
            Settings.cdnSelection = node.id
            self?.setupData()
        })
        alert.addAction(UIAlertAction(title: "編輯", style: .default) { [weak self] _ in
            self?.showManualCDNNodeEditor(node: node)
        })
        alert.addAction(UIAlertAction(title: "刪除", style: .destructive) { [weak self] _ in
            CDNNodeStore.removeManualNode(id: node.id)
            self?.setupData()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    func showManualCDNNodeEditor(node: CDNNode?) {
        let alert = UIAlertController(
            title: node == nil ? "新增手動節點" : "編輯手動節點",
            message: "hostname 範例：cn-example.bilivideo.com",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = node?.name
            textField.placeholder = "節點名稱（可留空）"
        }
        alert.addTextField { textField in
            textField.text = node?.host
            textField.placeholder = "CDN hostname"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "儲存", style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text ?? ""
            let host = alert?.textFields?.dropFirst().first?.text ?? ""
            do {
                if let node {
                    try CDNNodeStore.updateManualNode(id: node.id, name: name, host: host)
                } else {
                    try CDNNodeStore.addManualNode(name: name, host: host)
                }
                self?.setupData()
            } catch {
                self?.showCDNResult(title: "無法儲存", message: error.localizedDescription)
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    func showCDNListURLEditor() {
        let alert = UIAlertController(
            title: "GitHub CDN 清單網址",
            message: "支援 github.com 或 raw.githubusercontent.com 的 HTTPS JSON 網址。",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = Settings.cdnListURL
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "儲存", style: .default) { [weak self, weak alert] _ in
            guard let value = alert?.textFields?.first?.text else { return }
            Settings.cdnListURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
            Settings.cdnLastUpdate = Date(timeIntervalSince1970: 0)
            self?.setupData()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    func updateCDNList() {
        guard !isUpdatingCDNList else { return }
        isUpdatingCDNList = true
        setupData()
        Task { [weak self] in
            do {
                let count = try await CDNListUpdater.shared.updateNow()
                await MainActor.run {
                    self?.isUpdatingCDNList = false
                    self?.setupData()
                    self?.showCDNResult(title: "更新完成", message: "已從 GitHub 下載 \(count) 個 CDN 節點。")
                }
            } catch {
                await MainActor.run {
                    self?.isUpdatingCDNList = false
                    self?.setupData()
                    self?.showCDNResult(title: "更新失敗", message: error.localizedDescription)
                }
            }
        }
    }

    func confirmClearRemoteCDNNodes() {
        let alert = UIAlertController(title: "清除已下載清單？", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "清除", style: .destructive) { [weak self] _ in
            let remoteIDs = Set(Settings.cdnRemoteNodes.map(\.id))
            Settings.cdnRemoteNodes = []
            Settings.cdnLastUpdate = Date(timeIntervalSince1970: 0)
            if remoteIDs.contains(Settings.cdnSelection) {
                Settings.cdnSelection = CDNSelection.automatic.rawValue
            }
            self?.setupData()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    func showCDNResult(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        present(alert, animated: true)
    }

    @objc func cdnListDidUpdate() {
        setupData()
    }
}

extension SettingsViewController: UICollectionViewDelegate {
    private func createSnapshot(@ArrayBuilder<SectionModel> builder: () -> [SectionModel]) {
        var snapshot = NSDiffableDataSourceSnapshot<SectionModel, CellModel>()
        for section in builder() {
            snapshot.appendSections([section])
            snapshot.appendItems(section.items, toSection: section)
        }
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            self?.collectionView.reloadData()
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let cellModel = dataSource.itemIdentifier(for: indexPath)!
        cellModel.action?() { [weak cellModel] in
            cellModel?.updateAction?()
        }
    }
}

class SettingsSwitchCell: BLMotionCollectionViewCell {
    private let titleLabel = UILabel()
    private let descLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(with model: SettingsViewController.CellModel) {
        titleLabel.text = model.title
        descLabel.text = model.desp()
        model.updateAction = { [weak self] in
            self?.descLabel.text = model.desp()
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        updateColor()
    }

    func setupView() {
        contentView.addSubview(titleLabel)
        contentView.addSubview(descLabel)
        contentView.layer.cornerRadius = 10

        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(20)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(descLabel.snp.leading).offset(-10)
        }

        descLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-20)
            make.centerY.equalToSuperview()
        }

        descLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        updateColor()
    }

    func updateColor() {
        if traitCollection.userInterfaceStyle == .dark {
            if isFocused {
                contentView.backgroundColor = UIColor.white
                titleLabel.textColor = UIColor.black
                descLabel.textColor = UIColor.black
            } else {
                contentView.backgroundColor = UIColor.clear
                titleLabel.textColor = UIColor.white
                descLabel.textColor = UIColor.secondaryLabel
            }
        } else {
            contentView.backgroundColor = isFocused ? UIColor.white : UIColor.clear
            titleLabel.textColor = .black
            descLabel.textColor = UIColor.secondaryLabel
        }
    }
}

class SettingsHeaderView: UICollectionReusableView {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setup() {
        addSubview(label)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = UIColor.secondaryLabel
        label.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(20)
            make.top.equalToSuperview().offset(20)
            make.bottom.equalToSuperview().offset(-20)
        }
    }
}

extension FeedDisplayStyle {
    var desp: String {
        switch self {
        case .large:
            return "3个"
        case .normal:
            return "4个"
        case .sideBar:
            return "-"
        }
    }
}
