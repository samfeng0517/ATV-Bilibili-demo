//
//  CDNSettingsViewController.swift
//  BilibiliLive
//

import UIKit

final class CDNSettingsViewController: UIViewController {
    private struct Section: Hashable {
        let id: String
        let title: String
    }

    private struct Item: Hashable {
        let id: String
        let title: String
        let detail: () -> String
        let action: () -> Void

        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    private let collectionView: UICollectionView = {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let size = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .absolute(72)
            )
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 10
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(60)
            )
            section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: "header",
                alignment: .top
            )]
            return section
        }
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()

    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var isUpdating = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        collectionView.backgroundColor = .clear
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.delegate = self
        collectionView.register(CDNSettingsCell.self, forCellWithReuseIdentifier: CDNSettingsCell.reuseIdentifier)
        collectionView.register(
            SettingsHeaderView.self,
            forSupplementaryViewOfKind: "header",
            withReuseIdentifier: "HeaderView"
        )
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide).inset(40)
        }
        configureDataSource()
        reloadData()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteListDidUpdate),
            name: CDNListUpdater.didUpdateNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            collectionView, indexPath, item in
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: CDNSettingsCell.reuseIdentifier,
                for: indexPath
            ) as! CDNSettingsCell
            cell.configure(title: item.title, detail: item.detail())
            return cell
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: "HeaderView",
                for: indexPath
            ) as! SettingsHeaderView
            header.label.text = self?.dataSource.snapshot().sectionIdentifiers[indexPath.section].title
            return header
        }
    }

    private func reloadData() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

        let modeSection = Section(id: "mode", title: "CDN 使用方式")
        snapshot.appendSections([modeSection])
        snapshot.appendItems([
            Item(id: "selection", title: "使用節點", detail: { CDNNodeStore.selectionDescription }) { [weak self] in
                self?.showNodePicker()
            },
        ], toSection: modeSection)

        let manualSection = Section(id: "manual", title: "手動節點（\(Settings.cdnManualNodes.count)）")
        snapshot.appendSections([manualSection])
        var manualItems = [Item(
            id: "manual.add",
            title: "新增手動節點",
            detail: { "輸入名稱與 hostname" }
        ) { [weak self] in
            self?.showManualNodeEditor(node: nil)
        }]
        manualItems.append(contentsOf: Settings.cdnManualNodes.map { node in
            Item(id: "manual.\(node.id)", title: node.name, detail: { node.host }) { [weak self] in
                self?.showManualNodeActions(node)
            }
        })
        snapshot.appendItems(manualItems, toSection: manualSection)

        let githubSection = Section(id: "github", title: "GitHub 節點清單")
        snapshot.appendSections([githubSection])
        var githubItems = [
            Item(id: "github.auto", title: "自動更新", detail: { Settings.cdnAutoUpdate ? "開（每 24 小時）" : "關" }) { [weak self] in
                Settings.cdnAutoUpdate.toggle()
                self?.reloadData()
                if Settings.cdnAutoUpdate {
                    self?.updateRemoteList()
                }
            },
            Item(id: "github.url", title: "清單網址", detail: { Settings.cdnListURL }) { [weak self] in
                self?.showListURLEditor()
            },
            Item(id: "github.update", title: isUpdating ? "正在更新…" : "立即更新", detail: { [weak self] in
                self?.updateDescription ?? ""
            }) { [weak self] in
                self?.updateRemoteList()
            },
        ]
        githubItems.append(contentsOf: Settings.cdnRemoteNodes.map { node in
            Item(id: "github.\(node.id)", title: node.name, detail: { node.host }) { [weak self] in
                Settings.cdnSelection = node.id
                self?.reloadData()
            }
        })
        if !Settings.cdnRemoteNodes.isEmpty {
            githubItems.append(Item(id: "github.clear", title: "清除已下載清單", detail: { "" }) { [weak self] in
                self?.confirmClearRemoteNodes()
            })
        }
        snapshot.appendItems(githubItems, toSection: githubSection)
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            self?.collectionView.reloadData()
        }
    }

    private var updateDescription: String {
        if isUpdating {
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

    private func showNodePicker() {
        let alert = UIAlertController(title: "使用節點", message: "自動模式會讓播放前的既有測速流程從所有節點中擇優。", preferredStyle: .actionSheet)
        let choices: [(String, String)] = [
            (CDNSelection.automatic.rawValue, "自動選擇"),
            (CDNSelection.original.rawValue, "僅使用 Bilibili 原始節點"),
        ] + CDNNodeStore.allNodes.map { ($0.id, $0.name) }
        for (id, title) in choices {
            let displayedTitle = Settings.cdnSelection == id ? "✓ \(title)" : title
            let action = UIAlertAction(title: displayedTitle, style: .default) { [weak self] _ in
                Settings.cdnSelection = id
                self?.reloadData()
            }
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showManualNodeActions(_ node: CDNNode) {
        let alert = UIAlertController(title: node.name, message: node.host, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "使用這個節點", style: .default) { [weak self] _ in
            Settings.cdnSelection = node.id
            self?.reloadData()
        })
        alert.addAction(UIAlertAction(title: "編輯", style: .default) { [weak self] _ in
            self?.showManualNodeEditor(node: node)
        })
        alert.addAction(UIAlertAction(title: "刪除", style: .destructive) { [weak self] _ in
            CDNNodeStore.removeManualNode(id: node.id)
            self?.reloadData()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showManualNodeEditor(node: CDNNode?) {
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
                self?.reloadData()
            } catch {
                self?.showResult(title: "無法儲存", message: error.localizedDescription)
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showListURLEditor() {
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
            self?.reloadData()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func updateRemoteList() {
        guard !isUpdating else { return }
        isUpdating = true
        reloadData()
        Task { [weak self] in
            do {
                let count = try await CDNListUpdater.shared.updateNow()
                await MainActor.run {
                    self?.isUpdating = false
                    self?.reloadData()
                    self?.showResult(title: "更新完成", message: "已從 GitHub 下載 \(count) 個 CDN 節點。")
                }
            } catch {
                await MainActor.run {
                    self?.isUpdating = false
                    self?.reloadData()
                    self?.showResult(title: "更新失敗", message: error.localizedDescription)
                }
            }
        }
    }

    private func confirmClearRemoteNodes() {
        let alert = UIAlertController(title: "清除已下載清單？", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "清除", style: .destructive) { [weak self] _ in
            let remoteIDs = Set(Settings.cdnRemoteNodes.map(\.id))
            Settings.cdnRemoteNodes = []
            Settings.cdnLastUpdate = Date(timeIntervalSince1970: 0)
            if remoteIDs.contains(Settings.cdnSelection) {
                Settings.cdnSelection = CDNSelection.automatic.rawValue
            }
            self?.reloadData()
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    private func showResult(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func remoteListDidUpdate() {
        reloadData()
    }
}

extension CDNSettingsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        dataSource.itemIdentifier(for: indexPath)?.action()
    }
}

private final class CDNSettingsCell: BLMotionCollectionViewCell {
    static let reuseIdentifier = "CDNSettingsCell"

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 10
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.lineBreakMode = .byTruncatingMiddle
        contentView.addSubview(titleLabel)
        contentView.addSubview(detailLabel)
        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(20)
            make.centerY.equalToSuperview()
            make.width.lessThanOrEqualToSuperview().multipliedBy(0.42)
        }
        detailLabel.snp.makeConstraints { make in
            make.leading.greaterThanOrEqualTo(titleLabel.snp.trailing).offset(20)
            make.trailing.equalToSuperview().offset(-20)
            make.centerY.equalToSuperview()
        }
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, detail: String) {
        titleLabel.text = title
        detailLabel.text = detail
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        updateColors()
    }

    private func updateColors() {
        contentView.backgroundColor = isFocused ? .white : .clear
        titleLabel.textColor = isFocused ? .black : .label
        detailLabel.textColor = isFocused ? .darkGray : .secondaryLabel
    }
}
