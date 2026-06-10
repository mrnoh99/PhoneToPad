import SwiftUI
import Combine

enum DeviceRole: String {
    case unset      // 아직 역할 미선택
    case player     // 이 기기에서 음악 재생 (아이패드)
    case remote     // 리모컨 (아이폰)
}

/// 앱 전역 상태 + 네트워크/음악/볼륨 컨트롤러를 연결한다.
final class AppModel: ObservableObject {

    @Published var role: DeviceRole {
        didSet { UserDefaults.standard.set(role.rawValue, forKey: "role") }
    }
    /// 리모컨 측에서 표시할, 플레이어가 보내온 현재 곡 정보
    @Published var nowPlaying: NowPlayingMessage?

    let multipeer = MultipeerService()
    let music = MusicController()
    let volume = VolumeController()

    private var cancellables = Set<AnyCancellable>()

    init() {
        let saved = UserDefaults.standard.string(forKey: "role") ?? DeviceRole.unset.rawValue
        role = DeviceRole(rawValue: saved) ?? .unset
        wire()
    }

    private func wire() {
        // 리모컨 명령 수신 → 플레이어가 실행
        multipeer.onCommand = { [weak self] cmd in
            DispatchQueue.main.async { self?.handle(cmd) }
        }
        // 플레이어 곡정보 수신 → 리모컨 표시
        multipeer.onNowPlaying = { [weak self] np in
            DispatchQueue.main.async { self?.nowPlaying = np }
        }
        // 플레이어 곡정보 변동 → 리모컨에 전송
        music.onNowPlayingChanged = { [weak self] np in
            self?.multipeer.send(Packet(command: nil, nowPlaying: np))
        }
        // 볼륨이 실제 반영된 뒤에야 정확한 값을 다시 전송
        volume.onVolumeApplied = { [weak self] in
            self?.music.publishSoon()
        }
        // 연결되면 현재 상태를 즉시 한 번 보냄(플레이어 측)
        multipeer.$isConnected
            .removeDuplicates()
            .sink { [weak self] connected in
                guard let self, connected, self.role == .player else { return }
                self.music.publish()
            }
            .store(in: &cancellables)
    }

    // MARK: - 역할 시작
    func startPlayer() {
        role = .player
        multipeer.start(role: .player)
        music.requestAuthAndStart()
    }

    func startRemote() {
        role = .remote
        multipeer.start(role: .remote)
    }

    func resetRole() {
        multipeer.stop()
        nowPlaying = nil
        role = .unset
    }

    // MARK: - 리모컨 → 명령 전송
    func sendCommand(_ c: RemoteCommand) {
        multipeer.send(Packet(command: CommandMessage(command: c, volume: nil),
                              nowPlaying: nil))
    }

    func sendVolume(_ v: Float) {
        multipeer.send(Packet(command: CommandMessage(command: .setVolume, volume: v),
                              nowPlaying: nil))
    }

    // MARK: - 플레이어 측 명령 실행
    private func handle(_ cmd: CommandMessage) {
        switch cmd.command {
        case .play:       music.play()
        case .pause:      music.pause()
        case .playPause:  music.togglePlayPause()
        case .next:       music.next()
        case .prev:       music.prev()
        // 볼륨 명령은 실제 반영 후 volume.onVolumeApplied → publishSoon 으로 전송됨
        case .volumeUp:   volume.changeVolume(by: 0.0625)
        case .volumeDown: volume.changeVolume(by: -0.0625)
        case .setVolume:
            if let v = cmd.volume { volume.setVolume(v) }
        }
    }
}
