import SwiftUI
import Combine
import UIKit
import CoreImage

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
    /// 두 기기에 같은 값을 입력하면 그 코드끼리만 연결되는 페어링 코드(PIN). 비우면 같은 앱끼리 연결.
    @Published var pairingCode: String {
        didSet { UserDefaults.standard.set(pairingCode, forKey: "pairingCode") }
    }
    /// 리모컨 측에서 표시할, 플레이어가 보내온 현재 곡 정보
    @Published var nowPlaying: NowPlayingMessage?
    /// 현재 앨범아트에서 추출한 포인트 컬러(곡이 바뀌면 액센트가 바뀜). 아트 없으면 흰색.
    @Published var accent: Color = .white

    let multipeer = MultipeerService()
    let music = MusicController()
    let volume = VolumeController()

    private var cancellables = Set<AnyCancellable>()

    init() {
        let saved = UserDefaults.standard.string(forKey: "role") ?? DeviceRole.unset.rawValue
        role = DeviceRole(rawValue: saved) ?? .unset
        pairingCode = UserDefaults.standard.string(forKey: "pairingCode") ?? ""
        wire()
    }

    private func wire() {
        // 리모컨 명령 수신 → 플레이어가 실행
        multipeer.onCommand = { [weak self] cmd in
            DispatchQueue.main.async { self?.handle(cmd) }
        }
        // 플레이어 곡정보 수신 → 리모컨 표시 + 포인트 컬러 갱신
        multipeer.onNowPlaying = { [weak self] np in
            DispatchQueue.main.async {
                self?.nowPlaying = np
                self?.updateAccent(from: np.artworkJPEG)
            }
        }
        // 플레이어 곡정보 변동 → 리모컨에 전송 + (이 기기에서도) 포인트 컬러 갱신
        music.onNowPlayingChanged = { [weak self] np in
            self?.multipeer.send(Packet(command: nil, nowPlaying: np))
            DispatchQueue.main.async { self?.updateAccent(from: np.artworkJPEG) }
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
        multipeer.start(role: .player, code: pairingCode)
        music.requestAuthAndStart()
    }

    func startRemote() {
        role = .remote
        multipeer.start(role: .remote, code: pairingCode)
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

    // MARK: - 포인트 컬러(앨범아트 → 액센트)
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])
    /// 같은 곡정보가 반복 수신될 때(볼륨 변경 등) 재계산을 피하기 위한 캐시
    private var lastArtwork: Data?

    /// 앨범아트의 평균색을 구해 채도/밝기를 보정한 포인트 컬러로 갱신. 아트 없으면 흰색.
    private func updateAccent(from data: Data?) {
        guard data != lastArtwork else { return }   // 아트가 그대로면 스킵
        lastArtwork = data
        let color = data.flatMap { Self.dominantColor(from: $0) } ?? .white
        withAnimation(.easeInOut(duration: 0.5)) { accent = color }
    }

    /// CIAreaAverage 로 대표색을 뽑고, 너무 칙칙하지 않도록 HSB 보정
    private static func dominantColor(from data: Data) -> Color? {
        guard let ui = UIImage(data: data), let cg = ui.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input,
            kCIInputExtentKey: CIVector(cgRect: input.extent)
        ])
        guard let output = filter?.outputImage else { return nil }

        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &px, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: nil)

        let base = UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                           blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // 어두운 배경에서 또렷하게 보이도록 채도·밝기 하한 보정
        s = min(1, max(s, 0.55))
        b = min(1, max(b, 0.75))
        return Color(hue: Double(h), saturation: Double(s), brightness: Double(b))
    }
}
