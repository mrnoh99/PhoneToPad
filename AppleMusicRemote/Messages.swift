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
}

struct CommandMessage: Codable {
    var command: RemoteCommand
    var volume: Float? = nil    // setVolume 일 때만 사용
    var seekTime: Double? = nil // seek 일 때만 사용(초)
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
}
