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
struct MusicLibraryView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var net: MultipeerService

    @State private var category: LibraryCategory = .playlists
    @State private var searchText = ""

    private var request: LibraryRequest { LibraryRequest(category: category) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("분류", selection: $category) {
                    ForEach(LibraryCategory.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                LibraryListContent(app: app, net: net, request: request, searchText: searchText) { item in
                    if category == .songs {
                        app.playLibrary(PlayLibraryRequest(category: .songs, itemID: item.id))
                    }
                }
            }
            .navigationTitle("라이브러리")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "\(category.label) 검색")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { app.requestLibrary(request, force: true) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!net.isConnected || app.libraryLoading.contains(request))
                }
            }
            .navigationDestination(for: LibraryCollectionRef.self) { ref in
                LibraryCollectionView(app: app, net: net, ref: ref)
            }
        }
        .onAppear { app.requestLibrary(request) }
        .onChange(of: category) { _, _ in
            searchText = ""
            app.requestLibrary(request)
        }
        // 연결되면(재연결 포함) 현재 분류 목록을 받아온다.
        .onChange(of: net.isConnected) { _, connected in
            if connected { app.requestLibrary(request) }
        }
    }
}

/// 플레이리스트/앨범 상세 화면으로 이동하기 위한 값
struct LibraryCollectionRef: Hashable {
    var category: LibraryCategory
    var id: String
    var title: String
    var subtitle: String?
}

/// 목록 본문(로딩·에러·빈 목록 처리 + 검색 필터). 컬렉션은 상세로 이동, 노래는 onSelectSong.
private struct LibraryListContent: View {
    @ObservedObject var app: AppModel
    @ObservedObject var net: MultipeerService
    let request: LibraryRequest
    let searchText: String
    let onSelectSong: (LibraryItem) -> Void

    private var list: LibraryListMessage? { app.libraryLists[request] }
    private var isCollectionList: Bool { request.collectionID == nil && request.category != .songs }

    private var filtered: [LibraryItem] {
        let items = list?.items ?? []
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || ($0.subtitle?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        if let list {
            if let err = list.error {
                placeholder(icon: "lock.fill", text: err)
            } else if list.items.isEmpty {
                placeholder(icon: "music.note", text: "항목이 없습니다.")
            } else {
                List {
                    ForEach(filtered) { item in
                        if isCollectionList {
                            NavigationLink(value: LibraryCollectionRef(category: request.category, id: item.id,
                                                                       title: item.title, subtitle: item.subtitle)) {
                                LibraryRow(item: item, icon: request.category == .playlists
                                           ? "music.note.list" : "square.stack")
                            }
                        } else {
                            Button { onSelectSong(item) } label: {
                                LibraryRow(item: item, icon: "music.note")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if list.totalCount > list.items.count {
                        Text("전체 \(list.totalCount)개 중 \(list.items.count)개만 표시합니다.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .listStyle(.plain)
                .disabled(!net.isConnected)
            }
        } else if !net.isConnected {
            placeholder(icon: "ipad", text: "아이패드(플레이어) 연결을 기다리는 중")
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

    private func placeholder(icon: String, text: String) -> some View {
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

/// 플레이리스트/앨범 상세: 수록곡 목록 + 재생/셔플 버튼.
struct LibraryCollectionView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var net: MultipeerService
    let ref: LibraryCollectionRef

    @State private var searchText = ""

    private var request: LibraryRequest { LibraryRequest(category: ref.category, collectionID: ref.id) }
    private var hasItems: Bool { !(app.libraryLists[request]?.items.isEmpty ?? true) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(ref.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let s = ref.subtitle {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 12) {
                    playButton("재생", icon: "play.fill", shuffle: false)
                    playButton("셔플", icon: "shuffle", shuffle: true)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            LibraryListContent(app: app, net: net, request: request, searchText: searchText) { item in
                app.playLibrary(PlayLibraryRequest(category: ref.category, collectionID: ref.id, itemID: item.id))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "곡 검색")
        .onAppear { app.requestLibrary(request) }
        .onChange(of: net.isConnected) { _, connected in
            if connected { app.requestLibrary(request) }
        }
    }

    private func playButton(_ title: String, icon: String, shuffle: Bool) -> some View {
        Button {
            app.playLibrary(PlayLibraryRequest(category: ref.category, collectionID: ref.id, shuffle: shuffle))
        } label: {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(app.accent)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!net.isConnected || !hasItems)
        .opacity(net.isConnected && hasItems ? 1 : 0.4)
    }
}

/// 목록 한 줄
private struct LibraryRow: View {
    let item: LibraryItem
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.06))
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: icon).font(.system(size: 16)).foregroundStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let s = item.subtitle, !s.isEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let d = item.duration {
                Text(String(format: "%d:%02d", Int(d) / 60, Int(d) % 60))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}
