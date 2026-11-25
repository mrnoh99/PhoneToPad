import Foundation
import MediaPlayer

/// 플레이어(아이패드) 측: 기기의 음악 라이브러리(MPMediaQuery)를 읽어 목록을 만들고,
/// 리모컨이 고른 항목을 systemMusicPlayer 큐로 재생한다.
final class MusicLibraryProvider {

    /// 한 번에 보내는 최대 항목 수(네트워크 패킷 크기 제한용)
    static let maxItems = 3000

    private let queue = DispatchQueue(label: "com.mrnoh99.phonetopad.library", qos: .userInitiated)
    private var player: MPMusicPlayerController { .systemMusicPlayer }

    // MARK: - 목록

    /// 백그라운드에서 목록을 만들고 메인 스레드에서 completion 을 부른다.
    func list(_ request: LibraryRequest, completion: @escaping (LibraryListMessage) -> Void) {
        let finish: (LibraryListMessage) -> Void = { msg in
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
        queue.async { [weak self] in
            guard let self else { return }
            finish(self.buildList(request))
        }
    }

    private func buildList(_ request: LibraryRequest) -> LibraryListMessage {
        var all: [LibraryItem]
        if let cid = request.collectionID {
            let withNumbers = request.category == .albums
            all = (collectionItems(category: request.category, id: cid) ?? []).map {
                songItem($0, inAlbum: withNumbers)
            }
        } else {
            switch request.category {
            case .playlists:
                all = playlistTree()
            case .albums:
                // 앨범은 항상 collectionID(현재 곡의 앨범 ID)로 요청한다.
                all = []
            }
        }
        let total = all.count
        if all.count > Self.maxItems { all = Array(all.prefix(Self.maxItems)) }
        return LibraryListMessage(request: request, items: all, totalCount: total)
    }

    /// 전체 플레이리스트 + 폴더. Apple Music 의 폴더 구조(parentID)를 그대로 싣는다.
    /// 폴더/상위 정보는 공개 상수가 없어 MPMediaPlaylist 의 "isFolder" / "parentPersistentID" 속성을 읽는다.
    private func playlistTree() -> [LibraryItem] {
        let playlists = (MPMediaQuery.playlists().collections ?? []).compactMap { $0 as? MPMediaPlaylist }
        return playlists.map { pl in
            let isFolder = (pl.value(forProperty: "isFolder") as? NSNumber)?.boolValue ?? false
            let parent = (pl.value(forProperty: "parentPersistentID") as? NSNumber)?.uint64Value ?? 0
            return LibraryItem(id: String(pl.persistentID),
                               title: pl.name ?? (isFolder ? "이름 없는 폴더" : "이름 없는 플레이리스트"),
                               subtitle: isFolder ? nil : "\(pl.count)곡",
                               count: pl.count,
                               isFolder: isFolder ? true : nil,
                               parentID: parent != 0 ? String(parent) : nil)
        }
    }

    private func songItem(_ item: MPMediaItem, inAlbum: Bool) -> LibraryItem {
        let artist = item.artist ?? ""
        let sub: String
        if inAlbum {
            sub = artist
        } else {
            sub = [artist, item.albumTitle ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return LibraryItem(id: String(item.persistentID),
                           title: item.title ?? "알 수 없는 곡",
                           subtitle: sub.isEmpty ? nil : sub,
                           duration: item.playbackDuration > 0 ? item.playbackDuration : nil,
                           number: inAlbum && item.albumTrackNumber > 0 ? item.albumTrackNumber : nil)
    }

    /// 플레이리스트/앨범의 수록곡
    private func collectionItems(category: LibraryCategory, id: String) -> [MPMediaItem]? {
        guard let pid = UInt64(id) else { return nil }
        switch category {
        case .playlists:
            let q = MPMediaQuery.playlists()
            q.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: pid),
                                                          forProperty: MPMediaPlaylistPropertyPersistentID))
            return q.collections?.first?.items
        case .albums:
            let q = MPMediaQuery.songs()
            q.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: pid),
                                                          forProperty: MPMediaItemPropertyAlbumPersistentID))
            // 디스크/트랙 순서대로
            return (q.items ?? []).sorted {
                ($0.discNumber, $0.albumTrackNumber) < ($1.discNumber, $1.albumTrackNumber)
            }
        }
    }

    // MARK: - 재생

    /// 메인 스레드에서 호출. 큐를 바꾸고 재생을 시작한다. 성공 여부 반환.
    @discardableResult
    func play(_ request: PlayLibraryRequest) -> Bool {
        guard MPMediaLibrary.authorizationStatus() == .authorized,
              let cid = request.collectionID else { return false }

        let items = collectionItems(category: request.category, id: cid) ?? []
        guard !items.isEmpty else { return false }

        let start = request.itemID.flatMap { id in items.first { String($0.persistentID) == id } }

        if let shuffle = request.shuffle {
            player.shuffleMode = shuffle ? .songs : .off
        }
        player.setQueue(with: MPMediaItemCollection(items: items))
        if let start { player.nowPlayingItem = start }
        player.play()
        return true
    }
}
