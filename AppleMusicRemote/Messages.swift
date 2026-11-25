import Foundation

/// 리모컨(아이폰) → 플레이어(아이패드) 로 보내는 명령
enum RemoteCommand: String, Codable {
    case play
    case pause
    case playPause
    case next
    case prev
    case volumeUp
    case volumeDown
    case setVolume          // 함께 오는 `volume` 값으로 설정
    case syncNowPlaying     // 리모컨 복귀 시 플레이어에 곡정보 재전송 요청
    case toggleRepeat       // 반복 모드 순환(없음→전체→한곡)
    case toggleShuffle      // 셔플 켬/끔
    case seek               // 함께 오는 `seekTime`(초)로 구간 이동
    case requestLibrary     // 함께 오는 `library` 요청으로 라이브러리 목록 요청
    case playLibrary        // 함께 오는 `play` 요청으로 라이브러리 항목 재생
}

struct CommandMessage: Codable {
    var command: RemoteCommand
    var volume: Float? = nil    // setVolume 일 때만 사용
    var seekTime: Double? = nil // seek 일 때만 사용(초)
    var library: LibraryRequest? = nil      // requestLibrary 일 때만 사용
    var play: PlayLibraryRequest? = nil     // playLibrary 일 때만 사용
}

// MARK: - 음악 라이브러리 목록 (리모컨 ↔ 플레이어)

/// 라이브러리 목록 분류
enum LibraryCategory: String, Codable, CaseIterable, Identifiable {
    case playlists
    case albums      // 현재 재생 중인 곡의 앨범 수록곡

    var id: String { rawValue }

    var label: String {
        switch self {
        case .playlists: return "플레이리스트"
        case .albums:    return "앨범"
        }
    }
}

/// 리모컨 → 플레이어: 목록 요청. collectionID 가 있으면 그 플레이리스트/앨범의 수록곡을 요청.
struct LibraryRequest: Codable, Hashable {
    var category: LibraryCategory
    var collectionID: String? = nil
}

/// 리모컨 → 플레이어: 재생 요청.
/// collectionID 의 플레이리스트/앨범을 큐로 하고, itemID 가 있으면 그 곡부터 재생.
struct PlayLibraryRequest: Codable, Equatable {
    var category: LibraryCategory
    var collectionID: String? = nil
    var itemID: String? = nil
    var shuffle: Bool? = nil     // true 셔플 켬 / false 셔플 끔 / nil 그대로
}

/// 목록의 한 항목 (앨범아트 없이 가벼운 텍스트만)
struct LibraryItem: Codable, Equatable, Identifiable, Hashable {
    var id: String               // MPMediaEntityPersistentID 문자열
    var title: String
    var subtitle: String? = nil  // 아티스트 / 곡 수 등
    var duration: Double? = nil  // 노래일 때 길이(초)
    var count: Int? = nil        // 플레이리스트/앨범일 때 곡 수
    var number: Int? = nil       // 앨범 수록곡일 때 트랙 번호
    var isFolder: Bool? = nil    // 플레이리스트 폴더 여부
    var parentID: String? = nil  // 상위 플레이리스트 폴더 ID (최상위면 nil)
}

/// 플레이어 → 리모컨: 목록 응답
struct LibraryListMessage: Codable, Equatable {
    var request: LibraryRequest
    var items: [LibraryItem]
    var totalCount: Int          // 잘리기 전 전체 개수
    var error: String? = nil     // 권한 없음 등
}

/// 플레이어(아이패드) → 리모컨(아이폰) 으로 보내는 현재 재생 상태
struct NowPlayingMessage: Codable, Equatable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var volume: Float
    var artworkJPEG: Data?
    // 추가 메타데이터 / 모드 (라이브러리 곡일 때만 일부 채워짐)
    var composer: String? = nil
    var albumArtist: String? = nil
    var releaseDate: String? = nil
    var repeatMode: Int? = nil      // 0 없음, 1 한곡, 2 전체
    var shuffleMode: Int? = nil     // 0 끔, 1 켬
    /// 라이브러리 곡에 내장된 가사(있을 때만) — Apple Music 싱크 가사는 불가
    var lyrics: String? = nil
    /// MusicKit/iTunes 카탈로그에서 받아온 상세 정보
    var catalog: CatalogInfo? = nil
    /// 라이브러리 곡일 때 현재 곡 / 앨범의 persistentID (라이브러리 탭에서 앨범 목차·현재 곡 표시용)
    var itemID: String? = nil
    var albumID: String? = nil
}

/// MusicKit(우선) 또는 iTunes 검색으로 얻은 카탈로그 상세 정보 — 화면에 표시용
struct CatalogInfo: Codable, Equatable {
    var source: String? = nil          // "MusicKit" / "iTunes"
    var workName: String? = nil        // 작품(클래식)
    var movementName: String? = nil    // 악장(클래식)
    var movementNumber: Int? = nil
    var movementCount: Int? = nil
    var composerName: String? = nil
    var genres: [String]? = nil
    var albumTitle: String? = nil
    var trackNumber: Int? = nil
    var discNumber: Int? = nil
    var durationSeconds: Double? = nil
    var releaseDate: String? = nil
    var isExplicit: Bool? = nil
    var isrc: String? = nil
    var appleMusicURL: String? = nil
}

/// 재생 진행 위치 (자주 전송되는 가벼운 패킷 — 앨범아트 미포함)
struct PlaybackPosition: Codable {
    var elapsed: Double     // 경과(초)
    var duration: Double    // 전체 길이(초)
    var isPlaying: Bool
}

/// 한 줄로 양방향 송수신하기 위한 봉투(필요한 항목만 채워짐)
struct Packet: Codable {
    var command: CommandMessage? = nil
    var nowPlaying: NowPlayingMessage? = nil
    var position: PlaybackPosition? = nil
    var library: LibraryListMessage? = nil
}
