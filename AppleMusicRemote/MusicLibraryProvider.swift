import Foundation
import MediaPlayer

/// 플레이어(아이패드) 측: 기기의 음악 라이브러리(MPMediaQuery)를 읽어 목록을 만들고,
/// 리모컨이 고른 항목을 systemMusicPlayer 큐로 재생한다.
///
/// 현재 앨범 목차는 ① 라이브러리 앨범 ID → ② 라이브러리 앨범 제목 → ③ Apple Music 카탈로그(iTunes API)
/// 순서로 찾는다. 스트리밍(라이브러리에 없는) 곡도 ③으로 목차를 받아오고 store ID 로 재생한다.
final class MusicLibraryProvider {

    /// 한 번에 보내는 최대 항목 수(네트워크 패킷 크기 제한용)
    static let maxItems = 3000
    /// 카탈로그 항목/컬렉션 ID 접두어
    static let storePrefix = "store:"

    /// 라이브러리 밖 곡(Classical 등) 처리를 위한 현재 곡 정보(제목/아티스트/앨범)
    var nowPlayingHint: (() -> NowPlayingMessage?)?

    private let queue = DispatchQueue(label: "com.mrnoh99.phonetopad.library", qos: .userInitiated)
    private var player: MPMusicPlayerController { .systemMusicPlayer }

    /// 리모컨에서 마지막으로 재생한 플레이리스트(현재 플레이리스트 찾기에 우선 사용)
    private var lastPlayedPlaylistID: UInt64?
    /// 카탈로그 앨범 ID → 수록곡 store ID (재생용 캐시)
    private var catalogAlbumTracks: [String: [String]] = [:]

    // MARK: - 목록

    /// 메인 스레드에서 호출. 백그라운드에서 목록을 만들고 메인 스레드에서 completion 을 부른다.
    func list(_ request: LibraryRequest, completion: @escaping (LibraryListMessage) -> Void) {
        let build = AppInfo.build
        let finish: (LibraryListMessage) -> Void = { msg in
            var msg = msg
            msg.playerBuild = build
            DispatchQueue.main.async { completion(msg) }
        }
        let status = MPMediaLibrary.authorizationStatus()
        guard status == .authorized else {
            let reason = status == .notDetermined
                ? "아이패드에서 미디어 라이브러리 접근 권한을 허용해 주세요."
                : "아이패드 설정 › PhoneToPad › 미디어 및 Apple Music 접근을 허용해 주세요."
            finish(LibraryListMessage(request: request, items: [], totalCount: 0, error: reason))
            return
        }

        if request.current == true {
            // systemMusicPlayer 는 메인 스레드에서 읽는다.
            let hint = nowPlayingHint?()
            var item = player.nowPlayingItem
            // Classical 등 다른 앱 재생 중이면 systemMusicPlayer 의 곡이 다를 수 있다 → 그땐 무시
            if let h = hint, !h.title.isEmpty, let t = item?.title, t != h.title { item = nil }
            let snapshot = CurrentSnapshot(item: item,
                                           queueIndex: player.indexOfNowPlayingItem,
                                           shuffled: player.shuffleMode != .off,
                                           hint: hint,
                                           lastPlaylistID: lastPlayedPlaylistID)
            switch request.category {
            case .albums:
                queue.async { [weak self] in self?.currentAlbum(request, snapshot, finish: finish) }
            case .playlists:
                queue.async { [weak self] in
                    guard let self else { return }
                    finish(self.currentPlaylist(request, snapshot))
                }
            }
            return
        }

        if let cid = request.collectionID, cid.hasPrefix(Self.storePrefix) {
            // 카탈로그 앨범 목차 재요청
            let albumID = String(cid.dropFirst(Self.storePrefix.count))
            Task { [weak self] in
                guard let self else { return }
                let r = await self.catalogAlbum(collectionID: albumID)
                finish(self.catalogMessage(request, r))
            }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            finish(self.buildList(request))
        }
    }

    private struct CurrentSnapshot {
        var item: MPMediaItem?
        var queueIndex: Int
        var shuffled: Bool
        var hint: NowPlayingMessage?
        var lastPlaylistID: UInt64?

        var title: String { item?.title ?? hint?.title ?? "" }
        var artist: String { item?.artist ?? hint?.artist ?? "" }
        var album: String { item?.albumTitle ?? hint?.album ?? "" }
    }

    private func buildList(_ request: LibraryRequest) -> LibraryListMessage {
        var all: [LibraryItem]
        if let cid = request.collectionID {
            let inAlbum = request.category == .albums
            all = (collectionItems(category: request.category, id: cid) ?? []).map { songItem($0, inAlbum: inAlbum) }
        } else {
            switch request.category {
            case .playlists: all = playlistTree()
            case .albums:    all = []      // 앨범은 current 또는 collectionID 로 요청
            }
        }
        return message(request, all)
    }

    private func message(_ request: LibraryRequest, _ items: [LibraryItem],
                         collectionID: String? = nil, title: String? = nil, subtitle: String? = nil,
                         error: String? = nil, detail: String? = nil) -> LibraryListMessage {
        let total = items.count
        let capped = items.count > Self.maxItems ? Array(items.prefix(Self.maxItems)) : items
        return LibraryListMessage(request: request, items: capped, totalCount: total, error: error,
                                  collectionID: collectionID, collectionTitle: title, collectionSubtitle: subtitle,
                                  detail: detail)
    }

    /// 진단 기록 (비동기 단계 사이에서 공유)
    private final class Trace {
        var lines: [String] = []
        func add(_ s: String) { lines.append(s) }
        var text: String { lines.joined(separator: "\n") }
    }

    /// 전체 플레이리스트 + 폴더. Apple Music 의 폴더 구조(parentID)를 그대로 싣는다.
    /// 폴더/상위 정보는 공개 상수가 없어 MPMediaPlaylist 의 "isFolder" / "parentPersistentID" 속성을 읽는다.
    private func playlistTree() -> [LibraryItem] {
        allPlaylists().map { pl in
            let isFolder = Self.isFolder(pl)
            let parent = (pl.value(forProperty: "parentPersistentID") as? NSNumber)?.uint64Value ?? 0
            return LibraryItem(id: String(pl.persistentID),
                               title: pl.name ?? (isFolder ? "이름 없는 폴더" : "이름 없는 플레이리스트"),
                               subtitle: isFolder ? nil : "\(pl.count)곡",
                               count: pl.count,
                               isFolder: isFolder ? true : nil,
                               parentID: parent != 0 ? String(parent) : nil)
        }
    }

    private func allPlaylists() -> [MPMediaPlaylist] {
        (MPMediaQuery.playlists().collections ?? []).compactMap { $0 as? MPMediaPlaylist }
    }

    private static func isFolder(_ pl: MPMediaPlaylist) -> Bool {
        (pl.value(forProperty: "isFolder") as? NSNumber)?.boolValue ?? false
    }

    private func songItem(_ item: MPMediaItem, inAlbum: Bool) -> LibraryItem {
        let artist = item.artist ?? ""
        let sub = inAlbum ? artist
            : [artist, item.albumTitle ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return LibraryItem(id: String(item.persistentID),
                           title: item.title ?? "알 수 없는 곡",
                           subtitle: sub.isEmpty ? nil : sub,
                           duration: item.playbackDuration > 0 ? item.playbackDuration : nil,
                           number: inAlbum && item.albumTrackNumber > 0 ? item.albumTrackNumber : nil)
    }

    /// 플레이리스트/앨범의 수록곡 (라이브러리)
    private func collectionItems(category: LibraryCategory, id: String) -> [MPMediaItem]? {
        guard let pid = UInt64(id) else { return nil }
        switch category {
        case .playlists:
            return playlist(id: pid)?.items
        case .albums:
            return albumItems(predicate: MPMediaPropertyPredicate(value: NSNumber(value: pid),
                                                                  forProperty: MPMediaItemPropertyAlbumPersistentID))
        }
    }

    private func playlist(id: UInt64) -> MPMediaPlaylist? {
        let q = MPMediaQuery.playlists()
        q.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: id),
                                                      forProperty: MPMediaPlaylistPropertyPersistentID))
        return q.collections?.first as? MPMediaPlaylist
    }

    private func albumItems(predicate: MPMediaPropertyPredicate) -> [MPMediaItem] {
        let q = MPMediaQuery.songs()
        q.addFilterPredicate(predicate)
        return (q.items ?? []).sorted {
            ($0.discNumber, $0.albumTrackNumber) < ($1.discNumber, $1.albumTrackNumber)
        }
    }

    // MARK: - 현재 앨범

    private func currentAlbum(_ request: LibraryRequest, _ s: CurrentSnapshot,
                              finish: @escaping (LibraryListMessage) -> Void) {
        let trace = Trace()
        let albumArtist = s.item?.albumArtist ?? s.hint?.albumArtist ?? s.artist
        trace.add("곡: \(s.title) / \(s.artist) / 앨범: \(s.album.isEmpty ? "(없음)" : s.album)")
        if let item = s.item {
            trace.add("시스템 플레이어 곡: id=\(item.persistentID) albumID=\(item.albumPersistentID) storeID=\(item.playbackStoreID.isEmpty ? "-" : item.playbackStoreID)")
        } else {
            trace.add("시스템 플레이어 곡: 없음 (Classical 등 다른 앱이거나 곡 정보 불일치)")
        }

        // ① 라이브러리 앨범 ID
        if let item = s.item, item.albumPersistentID != 0 {
            let items = albumItems(predicate: MPMediaPropertyPredicate(
                value: NSNumber(value: item.albumPersistentID), forProperty: MPMediaItemPropertyAlbumPersistentID))
            trace.add("① 라이브러리 앨범 ID 조회: \(items.count)곡")
            if !items.isEmpty {
                finish(message(request, items.map { songItem($0, inAlbum: true) },
                               collectionID: String(item.albumPersistentID), title: s.album, subtitle: albumArtist,
                               detail: trace.text))
                return
            }
        }

        // ② 라이브러리 앨범 제목(+아티스트)
        if !s.album.isEmpty {
            var items = albumItems(predicate: MPMediaPropertyPredicate(
                value: s.album, forProperty: MPMediaItemPropertyAlbumTitle, comparisonType: .equalTo))
            let byArtist = items.filter {
                let a = ($0.albumArtist ?? $0.artist ?? "").lowercased()
                return !albumArtist.isEmpty && a == albumArtist.lowercased()
            }
            trace.add("② 라이브러리 앨범 제목 조회: \(items.count)곡 (아티스트 일치 \(byArtist.count)곡)")
            if !byArtist.isEmpty { items = byArtist }
            if let first = items.first, first.albumPersistentID != 0 {
                // 같은 앨범 ID 만 남긴다(같은 제목의 다른 앨범 섞임 방지)
                let pid = first.albumPersistentID
                let same = items.filter { $0.albumPersistentID == pid }
                finish(message(request, same.map { songItem($0, inAlbum: true) },
                               collectionID: String(pid), title: s.album, subtitle: albumArtist,
                               detail: trace.text))
                return
            }
        }

        // ③ Apple Music 카탈로그 (스트리밍 곡)
        let storeID = s.item?.playbackStoreID ?? ""
        let title = s.title, artist = s.artist, album = s.album
        guard !title.isEmpty || !storeID.isEmpty else {
            finish(message(request, [], error: "재생 중인 곡이 없습니다.", detail: trace.text))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let r = await self.catalogAlbum(storeID: storeID, title: title, artist: artist, album: album, trace: trace)
            finish(self.catalogMessage(request, r, trace: trace))
        }
    }

    // MARK: - 현재 플레이리스트

    private func currentPlaylist(_ request: LibraryRequest, _ s: CurrentSnapshot) -> LibraryListMessage {
        let pid = s.item?.persistentID ?? 0

        func result(_ pl: MPMediaPlaylist) -> LibraryListMessage {
            message(request, pl.items.map { songItem($0, inAlbum: false) },
                    collectionID: String(pl.persistentID), title: pl.name ?? "플레이리스트",
                    subtitle: "\(pl.count)곡")
        }

        // ① 리모컨에서 마지막으로 재생한 플레이리스트에 현재 곡이 있으면 그것
        if let last = s.lastPlaylistID, let pl = playlist(id: last),
           pid == 0 || pl.items.contains(where: { $0.persistentID == pid }) {
            return result(pl)
        }
        guard pid != 0 else {
            return message(request, [], error: "재생 중인 곡이 라이브러리에 없어 플레이리스트를 찾을 수 없습니다.")
        }
        // ② 현재 곡이 들어 있는 플레이리스트 중, 큐 위치까지 일치하는 것을 우선
        let candidates = allPlaylists().filter { pl in
            !Self.isFolder(pl) && pl.items.contains(where: { $0.persistentID == pid })
        }
        if !s.shuffled, s.queueIndex != NSNotFound, s.queueIndex >= 0,
           let exact = candidates.first(where: { pl in
               s.queueIndex < pl.items.count && pl.items[s.queueIndex].persistentID == pid
           }) {
            return result(exact)
        }
        // 큐 위치가 맞지 않으면 추측하지 않는다(앨범 등 다른 곡을 듣는 중일 수 있음 → 리모컨이 최근 플레이리스트로 대체)
        return message(request, [], error: "현재 곡이 들어 있는 플레이리스트를 찾지 못했습니다.")
    }

    // MARK: - Apple Music 카탈로그 (iTunes Search/Lookup API, 인증 불필요)

    private struct CatalogAlbum {
        var collectionID: String
        var title: String
        var artist: String
        var artworkURL: String?
        var tracks: [ITunesItem]
    }

    private func catalogMessage(_ request: LibraryRequest, _ r: CatalogAlbum?,
                                trace: Trace? = nil) -> LibraryListMessage {
        guard let r, !r.tracks.isEmpty else {
            return message(request, [], error: "이 곡의 앨범 목차를 찾지 못했습니다.", detail: trace?.text)
        }
        let items = r.tracks.compactMap { t -> LibraryItem? in
            guard let id = t.trackId else { return nil }
            return LibraryItem(id: Self.storePrefix + String(id),
                               title: t.trackName ?? "알 수 없는 곡",
                               subtitle: t.artistName,
                               duration: t.trackTimeMillis.map { Double($0) / 1000 },
                               number: t.trackNumber)
        }
        let cid = Self.storePrefix + r.collectionID
        let ids = r.tracks.compactMap { $0.trackId.map(String.init) }
        DispatchQueue.main.async { self.catalogAlbumTracks[cid] = ids }
        var msg = message(request, items, collectionID: cid, title: r.title, subtitle: r.artist, detail: trace?.text)
        msg.collectionArtworkURL = r.artworkURL
        return msg
    }

    /// 현재 곡의 카탈로그 앨범을 찾는다: store ID 직접 조회 → 실패하면 제목/아티스트 검색.
    private func catalogAlbum(storeID: String, title: String, artist: String, album: String,
                              trace: Trace) async -> CatalogAlbum? {
        var collectionID: Int?
        if !storeID.isEmpty, storeID != "0" {
            let r = await lookup(["id": storeID])
            collectionID = r?.first(where: { $0.collectionId != nil })?.collectionId
            trace.add("③ 카탈로그 store ID 조회: " + (r == nil ? "요청 실패(인터넷 연결 확인)"
                                                    : "\(r!.count)건, 앨범 ID \(collectionID.map(String.init) ?? "없음")"))
        }
        if collectionID == nil {
            // 아티스트+제목 → 제목+앨범 → 제목만 순서로 검색
            let terms = [[artist, title], [title, album], [title]]
                .map { $0.filter { !$0.isEmpty }.joined(separator: " ") }
                .filter { !$0.isEmpty }
            for term in NSOrderedSet(array: terms).array as! [String] {
                let results = await search(term: term)
                let best = results.flatMap { bestMatch($0, title: title, artist: artist, album: album) }
                trace.add("③ 카탈로그 검색 '\(term)': " + (results == nil ? "요청 실패(인터넷 연결 확인)"
                                                         : "\(results!.count)건" + (best?.collectionName.map { " → \($0)" } ?? "")))
                if let id = best?.collectionId { collectionID = id; break }
            }
        }
        guard let collectionID else { return nil }
        let r = await catalogAlbum(collectionID: String(collectionID))
        trace.add("③ 카탈로그 앨범 \(collectionID) 수록곡: " + (r == nil ? "요청 실패" : "\(r!.tracks.count)곡"))
        return r
    }

    /// 카탈로그 앨범 ID 로 수록곡(디스크/트랙 순)을 받아온다.
    /// 한국(KR) 등 곡 단위 판매가 없는 스토어는 앨범 정보만 주고 수록곡을 비워 보내므로,
    /// 수록곡이 없으면 지역 지정 없이 다시 조회한다. (트랙 ID 는 스토어 공통이라 그대로 재생 가능)
    private func catalogAlbum(collectionID: String) async -> CatalogAlbum? {
        let params = ["id": collectionID, "entity": "song", "limit": "200"]
        let base = "https://itunes.apple.com/lookup"
        let hasTracks: ([ITunesItem]?) -> Bool = { $0?.contains { $0.wrapperType == "track" } ?? false }
        var results = await fetch(base, params, country: Locale.current.region?.identifier)
        if !hasTracks(results) {
            results = await fetch(base, params, country: nil) ?? results
        }
        guard let results else { return nil }
        let header = results.first { $0.wrapperType == "collection" }
        let tracks = results.filter { $0.wrapperType == "track" }
            .sorted { ($0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.discNumber ?? 1, $1.trackNumber ?? 0) }
        return CatalogAlbum(collectionID: collectionID,
                            title: header?.collectionName ?? tracks.first?.collectionName ?? "",
                            artist: header?.artistName ?? tracks.first?.artistName ?? "",
                            artworkURL: (header?.artworkUrl100 ?? tracks.first?.artworkUrl100)
                                .map { $0.replacingOccurrences(of: "100x100", with: "1200x1200") },
                            tracks: tracks)
    }

    private func bestMatch(_ items: [ITunesItem], title: String, artist: String, album: String) -> ITunesItem? {
        let t = title.lowercased(), a = artist.lowercased(), al = album.lowercased()
        func score(_ i: ITunesItem) -> Int {
            var s = 0
            let ct = (i.trackName ?? "").lowercased()
            if ct == t { s += 3 } else if !ct.isEmpty, ct.contains(t) || t.contains(ct) { s += 1 }
            let ca = (i.artistName ?? "").lowercased()
            if ca == a { s += 2 } else if !a.isEmpty, !ca.isEmpty, ca.contains(a) || a.contains(ca) { s += 1 }
            let cal = (i.collectionName ?? "").lowercased()
            if !al.isEmpty, cal == al { s += 3 } else if !al.isEmpty, !cal.isEmpty, cal.contains(al) || al.contains(cal) { s += 1 }
            return s
        }
        return items.filter { $0.collectionId != nil }.max { score($0) < score($1) }
    }

    private func search(term: String) async -> [ITunesItem]? {
        guard !term.isEmpty else { return nil }
        return await request("https://itunes.apple.com/search",
                             ["term": term, "media": "music", "entity": "song", "limit": "25"])
    }

    private func lookup(_ params: [String: String]) async -> [ITunesItem]? {
        await request("https://itunes.apple.com/lookup", params)
    }

    /// 기기 지역 스토어로 먼저 조회하고, 결과가 없으면 지역 지정 없이(US) 다시 조회한다.
    /// 반환값 nil = 요청 자체 실패(네트워크 등), [] = 결과 없음.
    private func request(_ base: String, _ params: [String: String]) async -> [ITunesItem]? {
        let region = Locale.current.region?.identifier
        let first = await fetch(base, params, country: region)
        // 결과가 없거나 곡(track)이 하나도 없으면(KR 스토어 등) 지역 지정 없이 다시 조회
        if let first, first.contains(where: { $0.wrapperType == "track" }) { return first }
        guard region != nil else { return first }
        return await fetch(base, params, country: nil) ?? first
    }

    private func fetch(_ base: String, _ params: [String: String], country: String?) async -> [ITunesItem]? {
        guard var comps = URLComponents(string: base) else { return nil }
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let country { comps.queryItems?.append(URLQueryItem(name: "country", value: country)) }
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(ITunesResults.self, from: data) else { return nil }
        return decoded.results
    }

    private struct ITunesResults: Decodable { let results: [ITunesItem] }

    private struct ITunesItem: Decodable {
        let wrapperType: String?
        let trackId: Int?
        let collectionId: Int?
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let trackNumber: Int?
        let discNumber: Int?
        let trackTimeMillis: Int?
        let artworkUrl100: String?
    }

    // MARK: - 재생

    /// 실제 재생이 시작된 뒤 호출(곡 정보 재전송용)
    var onPlaybackStarted: (() -> Void)?
    /// 연속 탭 시 이전 재생 요청의 완료 처리를 무시하기 위한 세대 번호
    private var playGeneration = 0

    /// 메인 스레드에서 호출. 큐를 바꾸고 재생을 시작한다. 성공 여부 반환.
    ///
    /// systemMusicPlayer 는 setQueue 직후의 `nowPlayingItem` 지정이나 `startItemID` 를 무시하고 첫 곡부터
    /// 재생하는 경우가 있다. 그래서 시작 곡을 큐 디스크립터에 넣고 `prepareToPlay` 완료를 기다린 뒤,
    /// 실제로 고른 곡이 준비됐는지 확인하고 아니면 보정한 다음 재생한다.
    @discardableResult
    func play(_ request: PlayLibraryRequest) -> Bool {
        guard MPMediaLibrary.authorizationStatus() == .authorized,
              let cid = request.collectionID else { return false }

        if let shuffle = request.shuffle {
            player.shuffleMode = shuffle ? .songs : .off
        }

        // 카탈로그(스트리밍) 앨범: store ID 큐로 재생
        if cid.hasPrefix(Self.storePrefix) {
            guard let ids = catalogAlbumTracks[cid], !ids.isEmpty else { return false }
            lastPlayedPlaylistID = nil
            let target = request.itemID.flatMap { id -> String? in
                id.hasPrefix(Self.storePrefix) ? String(id.dropFirst(Self.storePrefix.count)) : nil
            }
            let descriptor = MPMusicPlayerStoreQueueDescriptor(storeIDs: ids)
            if let target { descriptor.startItemID = target }
            player.setQueue(with: descriptor)
            startPlayback(
                isCorrect: { [weak self] in
                    guard let target else { return true }
                    return self?.player.nowPlayingItem?.playbackStoreID == target
                },
                fix: { [weak self] in
                    // 시작 곡 지정이 무시되면 고른 곡부터 끝까지를 큐로 다시 지정한다.
                    guard let self, let target, let idx = ids.firstIndex(of: target) else { return }
                    self.player.setQueue(with: MPMusicPlayerStoreQueueDescriptor(storeIDs: Array(ids[idx...])))
                })
            return true
        }

        let items = collectionItems(category: request.category, id: cid) ?? []
        guard !items.isEmpty else { return false }
        // 앨범을 재생하면 더 이상 플레이리스트 재생 중이 아니다
        lastPlayedPlaylistID = request.category == .playlists ? UInt64(cid) : nil

        let start = request.itemID.flatMap { id in items.first { String($0.persistentID) == id } }
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: MPMediaItemCollection(items: items))
        if let start { descriptor.startItem = start }
        player.setQueue(with: descriptor)
        startPlayback(
            isCorrect: { [weak self] in
                guard let start else { return true }
                return self?.player.nowPlayingItem?.persistentID == start.persistentID
            },
            fix: { [weak self] in
                if let start { self?.player.nowPlayingItem = start }
            })
        return true
    }

    /// prepareToPlay 완료 후 시작 곡을 확인·보정하고 재생한다.
    private func startPlayback(isCorrect: @escaping () -> Bool, fix: @escaping () -> Void) {
        playGeneration += 1
        let generation = playGeneration
        let finish: () -> Void = { [weak self] in
            guard let self, generation == self.playGeneration else { return }
            let wasWrong = !isCorrect()
            if wasWrong { fix() }
            self.player.play()
            self.onPlaybackStarted?()
            // 보정이 필요했던 경우에만, 반영이 늦을 수 있어 한 번 더 확인 (사용자의 다음곡 조작을 되돌리지 않도록)
            guard wasWrong else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, generation == self.playGeneration else { return }
                if !isCorrect() {
                    fix()
                    self.player.play()
                    self.onPlaybackStarted?()
                }
            }
        }
        player.prepareToPlay { _ in
            DispatchQueue.main.async { finish() }
        }
    }
}
