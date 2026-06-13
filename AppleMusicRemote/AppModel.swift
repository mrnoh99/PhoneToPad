import SwiftUI
import Combine
import UIKit
import CoreImage
import MediaPlayer

enum DeviceRole: String {
    case unset      // 아직 역할 미선택
    case player     // 이 기기에서 음악 재생 (아이패드)
    case remote     // 리모컨 (아이폰)
}

/// 재생·제어 대상 앱 (아이패드 플레이어 측)
enum MusicAppSource: String, CaseIterable {
    case music
    case classical

    var label: String {
        switch self {
        case .music: return "Music"
        case .classical: return "Classical"
        }
    }

    /// 앱 실행에 시도할 URL 후보 (앞에서부터 canOpenURL 확인)
    var candidateURLs: [URL] {
        switch self {
        case .music:
            return ["music://", "musics://"].compactMap { URL(string: $0) }
        case .classical:
            return ["classical://", "music-classical://"].compactMap { URL(string: $0) }
        }
    }
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
    /// 제어할 음악 앱 (Music / Classical)
    @Published var musicSource: MusicAppSource = .music

    let multipeer = MultipeerService()
    let music = MusicController()
    let volume = VolumeController()

    private var cancellables = Set<AnyCancellable>()

    init() {
        let saved = UserDefaults.standard.string(forKey: "role") ?? DeviceRole.unset.rawValue
        role = DeviceRole(rawValue: saved) ?? .unset
        pairingCode = UserDefaults.standard.string(forKey: "pairingCode") ?? ""
        let savedSource = UserDefaults.standard.string(forKey: "musicSource") ?? MusicAppSource.music.rawValue
        musicSource = MusicAppSource(rawValue: savedSource) ?? .music
        music.preferredSource = musicSource
        wire()
        resumeNetworkingIfNeeded()
    }

    /// 앱 재실행 시 저장된 역할이 있으면 Multipeer 탐색을 다시 켠다.
    func resumeNetworkingIfNeeded() {
        switch role {
        case .player:
            guard !multipeer.isActive else { return }
            multipeer.start(role: .player, code: pairingCode)
            music.requestAuthAndStart()
        case .remote:
            guard !multipeer.isActive else { return }
            multipeer.start(role: .remote, code: pairingCode)
        case .unset:
            break
        }
    }

    /// Music / Classical 선택만 변경 (앱은 열지 않음)
    func selectMusicSource(_ source: MusicAppSource) {
        musicSource = source
        UserDefaults.standard.set(source.rawValue, forKey: "musicSource")
        music.preferredSource = source
        clearNowPlayingDisplay()
        music.invalidateAndRefresh()
    }

    /// 선택한 음악 앱을 연다 (별도 버튼용)
    @discardableResult
    func launchSelectedMusicApp() -> Bool {
        for url in musicSource.candidateURLs {
            guard UIApplication.shared.canOpenURL(url) else { continue }
            UIApplication.shared.open(url)
            return true
        }
        return false
    }

    /// 앱 전환·복귀 시 곡 정보를 다시 읽는다.
    func refreshNowPlayingFromSystem() {
        music.invalidateAndRefresh()
    }

    /// 화면 켜짐·포그라운드 복귀 시 연결·곡정보를 복구한다.
    func onBecomeActive() {
        resumeNetworkingIfNeeded()
        multipeer.wakeUp()
        switch role {
        case .player:
            if multipeer.isConnected {
                music.invalidateAndRefresh()
            }
        case .remote:
            // wakeUp 이 비동기라 연결 확인을 잠시 뒤에 한다
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.multipeer.isConnected else { return }
                self.sendCommand(.syncNowPlaying)
            }
        case .unset:
            break
        }
    }

    /// 이전 앱의 앨범아트/제목이 남지 않도록 표시 상태를 초기화한다.
    private func clearNowPlayingDisplay() {
        nowPlaying = nil
        lastArtwork = nil
        accent = .white
    }

    private func wire() {
        // 리모컨 명령 수신 → 플레이어가 실행
        multipeer.onCommand = { [weak self] cmd in
            self?.handle(cmd)
        }
        // 플레이어 곡정보 수신 → 리모컨 표시 + 포인트 컬러 갱신
        multipeer.onNowPlaying = { [weak self] np in
            DispatchQueue.main.async {
                self?.nowPlaying = np
                self?.updateAccent(from: np.artworkJPEG)
            }
        }
        // 플레이어 곡정보 변동 → 앨범 트랙목록 보강 후 리모컨에 전송 + 포인트 컬러 갱신
        music.onNowPlayingChanged = { [weak self] np in
            guard let self else { return }
            let enriched = self.enrichAlbumTracks(np)
            self.multipeer.send(Packet(command: nil, nowPlaying: enriched))
            DispatchQueue.main.async {
                self.nowPlaying = enriched
                self.updateAccent(from: enriched.artworkJPEG)
            }
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
                // 세션 핸드셰이크 직후 대용량 전송이 연결을 깨뜨리지 않도록 잠시 대기
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.multipeer.isConnected else { return }
                    self.music.invalidateAndRefresh()
                }
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
        case .syncNowPlaying:
            music.invalidateAndRefresh()
        }
    }

    // MARK: - 현재 앨범 트랙 목록 (플레이어 측, 라이브러리 조회)
    private var cachedAlbumID: MPMediaEntityPersistentID?
    private var cachedAlbumTracks: [String] = []

    /// 현재 재생 곡이 속한 앨범의 트랙 제목들을 라이브러리에서 조회해 메시지에 채운다.
    /// (스트리밍 전용 등 라이브러리에 없는 앨범은 비어 있어 그대로 둠) — 앨범 단위로 캐시.
    private func enrichAlbumTracks(_ msg: NowPlayingMessage) -> NowPlayingMessage {
        guard let item = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem else { return msg }
        let albumID = item.albumPersistentID
        guard albumID != 0 else { return msg }

        if albumID != cachedAlbumID {
            cachedAlbumID = albumID
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(MPMediaPropertyPredicate(
                value: albumID, forProperty: MPMediaItemPropertyAlbumPersistentID))
            let items = (query.items ?? []).sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                return $0.albumTrackNumber < $1.albumTrackNumber
            }
            cachedAlbumTracks = items.compactMap { $0.title }
        }

        guard !cachedAlbumTracks.isEmpty else { return msg }
        var result = msg
        result.albumTracks = cachedAlbumTracks
        result.currentTrackIndex = cachedAlbumTracks.firstIndex(of: msg.title)
        return result
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
