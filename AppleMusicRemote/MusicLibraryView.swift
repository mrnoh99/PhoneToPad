import SwiftUI

/// 리모컨 모드의 최상위 화면: [Now Playing] / [라이브러리] 두 탭.
struct RemoteRootView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var net: MultipeerService

    var body: some View {
        TabView(selection: $app.remoteTab) {
            RemoteControlView(app: app, net: net)
                .tag(RemoteTab.nowPlaying)
                .tabItem { Label("Now Playing", systemImage: "play.circle.fill") }

            MusicLibraryView(app: app, net: net)
                .tag(RemoteTab.library)
                .tabItem { Label("라이브러리", systemImage: "music.note.list") }
        }
    }
}

/// 라이브러리 탭: 아이패드(플레이어)의 음악 목록을 받아와 보여주고, 탭하면 아이패드에서 재생한다.
/// - 플레이리스트: Apple Music 의 폴더(트리) 구조 그대로
/// - 앨범: 지금 재생 중인 곡이 속한 앨범의 수록곡(목차)
struct MusicLibraryView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var net: MultipeerService

    @State private var category: LibraryCategory = .playlists
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("분류", selection: $category) {
                    ForEach(LibraryCategory.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                switch category {
                case .playlists:
                    PlaylistTreeList(app: app, net: net, parentID: nil, searchText: searchText)
                case .albums:
                    CurrentAlbumView(app: app, net: net, searchText: searchText)
                }
            }
            .navigationTitle("라이브러리")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: category == .playlists ? "플레이리스트 검색" : "곡 검색")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(!net.isConnected)
                }
            }
            .navigationDestination(for: PlaylistFolderRef.self) { ref in
                PlaylistFolderScreen(app: app, net: net, ref: ref)
            }
            .navigationDestination(for: LibraryCollectionRef.self) { ref in
                LibraryCollectionView(app: app, net: net, ref: ref)
            }
        }
        .onChange(of: category) { _, _ in searchText = "" }
    }

    private func refresh() {
        switch category {
        case .playlists:
            app.requestLibrary(.playlistTree, force: true)
        case .albums:
            if let id = app.nowPlaying?.albumID {
                app.requestLibrary(LibraryRequest(category: .albums, collectionID: id), force: true)
            }
        }
    }
}

extension LibraryRequest {
    /// 전체 플레이리스트(폴더 포함) 목록 요청
    static let playlistTree = LibraryRequest(category: .playlists)
}

// MARK: - 플레이리스트 트리

/// 플레이리스트 폴더로 들어가기 위한 값
struct PlaylistFolderRef: Hashable {
    var id: String
    var title: String
}

/// 플레이리스트 상세(수록곡)로 이동하기 위한 값
struct LibraryCollectionRef: Hashable {
    var category: LibraryCategory
    var id: String
    var title: String
    var subtitle: String?
}

/// 폴더 안 화면 (자체 검색 포함)
private struct PlaylistFolderScreen: View {
    @ObservedObject var app: AppModel
    @ObservedObject var net: MultipeerService
    let ref: PlaylistFolderRef
    @State private var searchText = ""

    var body: some View {
        PlaylistTreeList(app: app, net: net, parentID: ref.id, searchText: searchText)
            .navigationTitle(ref.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "플레이리스트 검색")
    }
}

/// 한 단계(parentID 바로 아래)의 폴더·플레이리스트 목록. 검색 중이면 하위 전체에서 플레이리스트를 찾는다.
private struct PlaylistTreeList: View {
    @ObservedObject var app: AppModel
    @ObservedObject var net: MultipeerService
    let parentID: String?
    let searchText: String

    var body: some View {
        LibraryLoadState(app: app, net: net, request: .playlistTree) { list in
            let visible = rows(in: list.items)
            if visible.isEmpty {
                LibraryPlaceholder(icon: "music.note.list",
                                   text: searchText.isEmpty ? "플레이리스트가 없습니다." : "검색 결과가 없습니다.")
            } else {
                List(visible) { item in
                    if item.isFolder == true {
                        NavigationLink(value: PlaylistFolderRef(id: item.id, title: item.title)) {
                            LibraryRow(title: item.title,
                                       subtitle: "\(childCount(of: item.id, in: list.items))개 항목",
                                       leading: .icon("folder"))
                        }
                    } else {
                        NavigationLink(value: LibraryCollectionRef(category: .playlists, id: item.id,
                                                                   title: item.title, subtitle: item.subtitle)) {
                            LibraryRow(title: item.title, subtitle: item.subtitle,
                                       leading: .icon("music.note.list"))
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    /// 상위 폴더가 목록에 없으면 최상위로 취급한다.
    private func parent(of item: LibraryItem, ids: Set<String>) -> String? {
        guard let p = item.parentID, ids.contains(p) else { return nil }
        return p
    }

    private func rows(in items: [LibraryItem]) -> [LibraryItem] {
        let ids = Set(items.map(\.id))
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            // 이 폴더의 모든 하위(자손)에서 이름으로 검색
            let scope = descendants(of: parentID, in: items, ids: ids)
            return scope.filter { $0.isFolder != true && $0.title.localizedCaseInsensitiveContains(q) }
        }
        let children = items.filter { parent(of: $0, ids: ids) == parentID }
        // Apple Music 처럼 폴더를 위에, 나머지는 원래 순서
        return children.filter { $0.isFolder == true } + children.filter { $0.isFolder != true }
    }

    private func descendants(of root: String?, in items: [LibraryItem], ids: Set<String>) -> [LibraryItem] {
        guard let root else { return items }
        var result: [LibraryItem] = []
        var frontier: Set<String> = [root]
        var visited: Set<String> = [root]
        while !frontier.isEmpty {
            let level = items.filter { item in
                guard let p = parent(of: item, ids: ids) else { return false }
                return frontier.contains(p) && !visited.contains(item.id)
            }
            result += level
            frontier = Set(level.map(\.id))
            visited.formUnion(frontier)
        }
        return result
    }

    private func childCount(of id: String, in items: [LibraryItem]) -> Int {
        items.filter { $0.parentID == id }.count
    }
}

/// 플레이리스트 상세: 수록곡 목록 + 재생/셔플 버튼.
struct LibraryCollectionView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var net: MultipeerService
    let ref: LibraryCollectionRef

    @State private var searchText = ""

    private var request: LibraryRequest { LibraryRequest(category: ref.category, collectionID: ref.id) }
    private var hasItems: Bool { !(app.libraryLists[request]?.items.isEmpty ?? true) }

    var body: some View {
        VStack(spacing: 0) {
            CollectionHeader(app: app, title: ref.title, subtitle: ref.subtitle,
                             enabled: net.isConnected && hasItems) { shuffle in
                app.playLibrary(PlayLibraryRequest(category: ref.category, collectionID: ref.id, shuffle: shuffle))
            }
            LibraryLoadState(app: app, net: net, request: request) { list in
                TrackList(app: app, items: list.items, searchText: searchText, showNumbers: false,
                          totalCount: list.totalCount) { item in
                    app.playLibrary(PlayLibraryRequest(category: ref.category, collectionID: ref.id,
                                                       itemID: item.id))
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "곡 검색")
    }
}

// MARK: - 현재 앨범

/// 지금 재생 중인 곡의 앨범 목차. 곡이 다른 앨범으로 바뀌면 자동으로 다시 받아온다.
private struct CurrentAlbumView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var net: MultipeerService
    let searchText: String

    private var albumID: String? { app.nowPlaying?.albumID }

    var body: some View {
        if !net.isConnected && app.nowPlaying == nil {
            LibraryPlaceholder(icon: "ipad", text: "아이패드(플레이어) 연결을 기다리는 중")
        } else if let albumID, let np = app.nowPlaying {
            let request = LibraryRequest(category: .albums, collectionID: albumID)
            let hasItems = !(app.libraryLists[request]?.items.isEmpty ?? true)
            VStack(spacing: 0) {
                CollectionHeader(app: app, title: np.album.isEmpty ? "알 수 없는 앨범" : np.album,
                                 subtitle: (np.albumArtist?.isEmpty == false ? np.albumArtist : nil) ?? np.artist,
                                 enabled: net.isConnected && hasItems) { shuffle in
                    app.playLibrary(PlayLibraryRequest(category: .albums, collectionID: albumID, shuffle: shuffle),
                                    showNowPlaying: false)
                }
                LibraryLoadState(app: app, net: net, request: request) { list in
                    TrackList(app: app, items: list.items, searchText: searchText, showNumbers: true,
                              totalCount: list.totalCount) { item in
                        // 목차를 보면서 곡을 고르는 화면이라 탭을 바꾸지 않고 현재 곡 표시만 갱신
                        app.playLibrary(PlayLibraryRequest(category: .albums, collectionID: albumID,
                                                           itemID: item.id),
                                        showNowPlaying: false)
                    }
                }
            }
        } else {
            LibraryPlaceholder(icon: "square.stack",
                               text: "재생 중인 앨범이 없습니다.\n아이패드에서 라이브러리에 있는 곡을 재생하면 앨범 목차가 표시됩니다.")
        }
    }
}

// MARK: - 공용 구성 요소

/// 요청한 목록의 상태(연결 대기 / 로딩 / 에러 / 완료)를 처리하고, 완료되면 content 를 그린다.
/// 화면이 보일 때와 (재)연결될 때 자동으로 요청한다.
private struct LibraryLoadState<Content: View>: View {
    @ObservedObject var app: AppModel
    @ObservedObject var net: MultipeerService
    let request: LibraryRequest
    @ViewBuilder let content: (LibraryListMessage) -> Content

    var body: some View {
        Group {
            if let list = app.libraryLists[request] {
                if let err = list.error {
                    LibraryPlaceholder(icon: "lock.fill", text: err)
                } else {
                    content(list)
                }
            } else if !net.isConnected {
                LibraryPlaceholder(icon: "ipad", text: "아이패드(플레이어) 연결을 기다리는 중")
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("목록을 받아오는 중…").font(.subheadline).foregroundStyle(.secondary)
                    if !app.libraryLoading.contains(request) {
                        Button("다시 시도") { app.requestLibrary(request, force: true) }
                            .font(.footnote)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { app.requestLibrary(request) }
        .onChange(of: request) { _, newValue in app.requestLibrary(newValue) }
        .onChange(of: net.isConnected) { _, connected in
            if connected { app.requestLibrary(request) }
        }
    }
}

/// 곡 목록. 현재 재생 중인 곡은 포인트 컬러 + 스피커 아이콘으로 표시한다.
private struct TrackList: View {
    @ObservedObject var app: AppModel
    let items: [LibraryItem]
    let searchText: String
    let showNumbers: Bool
    let totalCount: Int
    let onSelect: (LibraryItem) -> Void

    private var filtered: [LibraryItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || ($0.subtitle?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private func leading(for item: LibraryItem, index: Int, current: Bool) -> LibraryRow.Leading {
        if showNumbers { return current ? .playing : .number(item.number ?? index + 1) }
        return .icon(current ? "speaker.wave.2.fill" : "music.note")
    }

    var body: some View {
        if items.isEmpty {
            LibraryPlaceholder(icon: "music.note", text: "곡이 없습니다.")
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                        let current = item.id == app.nowPlaying?.itemID
                        Button { onSelect(item) } label: {
                            LibraryRow(title: item.title, subtitle: item.subtitle, duration: item.duration,
                                       leading: leading(for: item, index: index, current: current),
                                       highlight: current ? app.accent : nil)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                    if totalCount > items.count {
                        Text("전체 \(totalCount)곡 중 \(items.count)곡만 표시합니다.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .listStyle(.plain)
                // 현재 곡이 보이도록 스크롤
                .onAppear {
                    if let id = app.nowPlaying?.itemID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

/// 플레이리스트/앨범 헤더: 제목 + 재생/셔플 버튼
private struct CollectionHeader: View {
    @ObservedObject var app: AppModel
    let title: String
    let subtitle: String?
    let enabled: Bool
    let onPlay: (_ shuffle: Bool) -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let s = subtitle, !s.isEmpty {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 12) {
                button("재생", icon: "play.fill", shuffle: false)
                button("셔플", icon: "shuffle", shuffle: true)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func button(_ title: String, icon: String, shuffle: Bool) -> some View {
        Button { onPlay(shuffle) } label: {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(app.accent)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

private struct LibraryPlaceholder: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 36, weight: .thin)).foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 목록 한 줄
private struct LibraryRow: View {
    enum Leading {
        case icon(String)
        case number(Int)
        case playing
    }

    let title: String
    var subtitle: String? = nil
    var duration: Double? = nil
    var leading: Leading
    var highlight: Color? = nil

    var body: some View {
        HStack(spacing: 12) {
            leadingView
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(highlight == nil ? .regular : .semibold))
                    .foregroundStyle(highlight ?? .white)
                    .lineLimit(1)
                if let s = subtitle, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let d = duration {
                Text(String(format: "%d:%02d", Int(d) / 60, Int(d) % 60))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var leadingView: some View {
        switch leading {
        case .icon(let name):
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.06))
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: name).font(.system(size: 16)).foregroundStyle(.secondary))
        case .number(let n):
            Text("\(n)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        case .playing:
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14))
                .foregroundStyle(highlight ?? .white)
                .frame(width: 28, alignment: .trailing)
        }
    }
}
