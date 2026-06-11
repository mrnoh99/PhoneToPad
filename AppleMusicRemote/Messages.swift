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
}

struct CommandMessage: Codable {
    var command: RemoteCommand
    var volume: Float?      // setVolume 일 때만 사용
}

/// 플레이어(아이패드) → 리모컨(아이폰) 으로 보내는 현재 재생 상태
struct NowPlayingMessage: Codable, Equatable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var volume: Float
    var artworkJPEG: Data?
}

/// 한 줄로 양방향 송수신하기 위한 봉투(둘 중 하나만 채워짐)
struct Packet: Codable {
    var command: CommandMessage?
    var nowPlaying: NowPlayingMessage?
}
