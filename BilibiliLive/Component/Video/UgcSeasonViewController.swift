//
//  UgcSeasonViewController.swift
//  BilibiliLive
//

import SnapKit
import UIKit

struct UgcSeasonDescriptor: Hashable {
    let seasonId: Int
    let mid: Int
    let title: String
    let intro: String
    let cover: URL?
    let initialFollowing: Bool?

    init(season: VideoDetail.Info.UgcSeason) {
        seasonId = season.id
        mid = season.mid
        title = season.title
        intro = season.intro
        cover = season.cover
        initialFollowing = season.sign_state.map { $0 != 0 }
    }

    init(summary: WebRequest.UpSpaceSeasonSummary) {
        seasonId = summary.season_id
        mid = summary.mid
        title = summary.title
        intro = summary.description ?? ""
        cover = summary.cover
        initialFollowing = nil
    }
}

final class UgcSeasonViewController: StandardVideoCollectionViewController<WebRequest.UpSpaceSeasonVideo> {
    private let season: UgcSeasonDescriptor
    private var isFollowing: Bool
    private var isUpdatingFollowState = false
    private weak var seasonHeaderView: UgcSeasonTitleSupplementaryView?

    init(season: UgcSeasonDescriptor) {
        self.season = season
        isFollowing = season.initialFollowing ?? false
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setupCollectionView() {
        collectionVC.styleOverride = .normal
        collectionVC.showHeader = true
        collectionVC.customHeaderConfig = FeedHeaderConfig(
            viewType: UgcSeasonTitleSupplementaryView.self,
            estimatedHeight: 150
        ) { [weak self] headerView, _ in
            guard let self else { return }
            seasonHeaderView = headerView
            headerView.configure(
                title: season.title,
                intro: season.intro,
                isFollowing: isFollowing
            )
            headerView.isUpdating = isUpdatingFollowState
            headerView.onFollowTapped = { [weak self] followed in
                self?.updateFollowState(to: followed)
            }
        }
        super.setupCollectionView()
    }

    override func request(page: Int) async throws -> [WebRequest.UpSpaceSeasonVideo] {
        async let videos = WebRequest.requestUpSpaceSeasonVideos(
            mid: season.mid,
            seasonId: season.seasonId,
            page: page
        )

        if page == 1, let followed = try? await WebRequest.requestIsUgcSeasonFollowed(seasonId: season.seasonId) {
            isFollowing = followed
            seasonHeaderView?.isFollowing = followed
        }
        return try await videos
    }

    private func updateFollowState(to followed: Bool) {
        guard !isUpdatingFollowState else { return }
        let previousState = isFollowing
        isFollowing = followed
        isUpdatingFollowState = true
        seasonHeaderView?.isFollowing = followed
        seasonHeaderView?.isUpdating = true

        Task { [weak self] in
            guard let self else { return }
            do {
                try await WebRequest.setUgcSeasonFollowed(
                    seasonId: season.seasonId,
                    followed: followed
                )
                isUpdatingFollowState = false
                seasonHeaderView?.isUpdating = false
            } catch {
                isFollowing = previousState
                isUpdatingFollowState = false
                seasonHeaderView?.isFollowing = previousState
                seasonHeaderView?.isUpdating = false
                presentFollowError(error, attemptedFollowState: followed)
            }
        }
    }

    private func presentFollowError(_ error: Error, attemptedFollowState: Bool) {
        let action = attemptedFollowState ? "追蹤" : "取消追蹤"
        let alert = UIAlertController(
            title: "無法\(action)合集",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        present(alert, animated: true)
    }
}

final class UpSpaceSeasonsViewController: UIViewController {
    private let mid: Int
    private let uploaderName: String
    private let collectionVC = FeedCollectionViewController()
    private let loadingView = UIActivityIndicatorView(style: .large)

    init(mid: Int, uploaderName: String) {
        self.mid = mid
        self.uploaderName = uploaderName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [collectionVC.collectionView].compactMap { $0 }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionVC.styleOverride = .normal
        collectionVC.showHeader = true
        collectionVC.headerText = "\(uploaderName) 建立的合集"
        collectionVC.didSelect = { [weak self] displayData in
            guard let self,
                  let summary = displayData as? WebRequest.UpSpaceSeasonSummary
            else { return }
            present(
                UgcSeasonViewController(season: UgcSeasonDescriptor(summary: summary)),
                animated: true
            )
        }
        collectionVC.show(in: self)
        setupLoadingView()
        loadSeasons()
    }

    private func setupLoadingView() {
        view.addSubview(loadingView)
        loadingView.color = .white
        loadingView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        loadingView.startAnimating()
    }

    private func loadSeasons() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let seasons = try await WebRequest.requestAllUpSpaceSeasons(mid: mid)
                collectionVC.headerText = seasons.isEmpty
                    ? "\(uploaderName) 尚未建立合集"
                    : "\(uploaderName) 建立的合集"
                collectionVC.displayDatas = seasons
                loadingView.stopAnimating()
            } catch {
                loadingView.stopAnimating()
                let alert = UIAlertController(
                    title: "無法取得合集",
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "重試", style: .default) { [weak self] _ in
                    self?.loadingView.startAnimating()
                    self?.loadSeasons()
                })
                alert.addAction(UIAlertAction(title: "取消", style: .cancel))
                present(alert, animated: true)
            }
        }
    }
}

final class UgcSeasonTitleSupplementaryView: UICollectionReusableView {
    private let titleLabel = UILabel()
    private let introLabel = UILabel()
    private let followButton = BLIconTextButton()

    var onFollowTapped: ((Bool) -> Void)?

    var isFollowing = false {
        didSet {
            followButton.isOn = isFollowing
            followButton.title = isFollowing ? "取消追蹤" : "追蹤合集"
            followButton.accessibilityLabel = followButton.title
        }
    }

    var isUpdating = false {
        didSet {
            followButton.isEnabled = !isUpdating
            followButton.alpha = isUpdating ? 0.55 : 1
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, intro: String, isFollowing: Bool) {
        titleLabel.text = title
        introLabel.text = intro.isEmpty ? "此合集的全部影片" : intro
        self.isFollowing = isFollowing
    }

    private func setupUI() {
        addSubview(titleLabel)
        addSubview(introLabel)
        addSubview(followButton)

        titleLabel.font = .systemFont(ofSize: 42, weight: .semibold)
        titleLabel.numberOfLines = 1
        introLabel.font = .systemFont(ofSize: 24)
        introLabel.textColor = UIColor(named: "titleColor") ?? .lightGray
        introLabel.numberOfLines = 2

        followButton.title = "追蹤合集"
        followButton.titleFont = .systemFont(ofSize: 23, weight: .semibold)
        followButton.image = UIImage(systemName: "heart")
        followButton.onImage = UIImage(systemName: "heart.fill")
        followButton.onPrimaryAction = { [weak self] _ in
            guard let self, !isUpdating else { return }
            onFollowTapped?(!isFollowing)
        }

        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(60)
            make.top.equalToSuperview().offset(18)
            make.trailing.lessThanOrEqualTo(followButton.snp.leading).offset(-40)
        }
        introLabel.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel)
            make.top.equalTo(titleLabel.snp.bottom).offset(10)
            make.trailing.lessThanOrEqualTo(followButton.snp.leading).offset(-40)
            make.bottom.lessThanOrEqualToSuperview().offset(-18)
        }
        followButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-70)
            make.centerY.equalToSuperview()
            make.width.equalTo(210)
            make.height.equalTo(64)
        }
    }
}
