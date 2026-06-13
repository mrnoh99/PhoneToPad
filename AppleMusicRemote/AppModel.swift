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
    /// 리모컨 측 진행 위치(플레이어가 1초마다 보내옴) + 받은 시각(로컬 보간용)
    @Published var playback: PlaybackPosition?
    private var playbackReceivedAt = Date()

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
        playback = nil
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
        // 리모컨: 진행 위치 수신 → 보간용 기준값 저장
        multipeer.onPosition = { [weak self] pos in
            DispatchQueue.main.async {
                self?.playback = pos
                self?.playbackReceivedAt = Date()
            }
        }
        // 플레이어 곡정보 변동 → 메타데이터/모드 보강 후 전송 + 포인트 컬러 갱신
        music.onNowPlayingChanged = { [weak self] np in
            guard let self else { return }
            let enriched = self.enrichNowPlaying(np)
            self.multipeer.send(Packet(nowPlaying: enriched))
            DispatchQueue.main.async {
                self.nowPlaying = enriched
                self.updateAccent(from: enriched.artworkJPEG)
            }
        }
        // 볼륨이 실제 반영된 뒤에야 정확한 값을 다시 전송
        volume.onVolumeApplied = { [weak self] in
            self?.music.publishSoon()
        }
        // 연결 상태 변화(플레이어 측): 연결되면 곡정보 갱신 + 진행위치 송신 시작
        multipeer.$isConnected
            .removeDuplicates()
            .sink { [weak self] connected in
                guard let self, self.role == .player else { return }
                if connected {
                    // 세션 핸드셰이크 직후 대용량 전송이 연결을 깨뜨리지 않도록 잠시 대기
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, self.multipeer.isConnected else { return }
                        self.music.invalidateAndRefresh()
                    }
                    self.startPositionUpdates()
                } else {
                    self.stopPositionUpdates()
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
        stopPositionUpdates()
        nowPlaying = nil
        playback = nil
        role = .unset
    }

    // MARK: - 리모컨 → 명령 전송
    func sendCommand(_ c: RemoteCommand) {
        multipeer.send(Packet(command: CommandMessage(command: c, volume: nil),
                              nowPlaying: nil))
    }

    func sendVolume(_ v: Float) {
        multipeer.send(Packet(command: CommandMessage(command: .setVolume, volume: v)))
    }

    /// 진행바 드래그 → 구간 이동 요청
    func sendSeek(to time: Double) {
        multipeer.send(Packet(command: CommandMessage(command: .seek, seekTime: time)))
    }

    /// 리모컨에서 보간한 현재 경과 시간(초) — 재생 중이면 받은 시점부터 흐른 시간을 더함
    func currentElapsed() -> Double {
        guard let p = playback else { return 0 }
        let extra = p.isPlaying ? Date().timeIntervalSince(playbackReceivedAt) : 0
        return min(p.duration, max(0, p.elapsed + extra))
    }

    // MARK: - 플레이어 측 명령 실행
    private func handle(_ cmd: CommandMessage) {
        let sp = MPMusicPlayerController.systemMusicPlayer
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
        case .toggleRepeat:
            sp.repeatMode = Self.nextRepeat(sp.repeatMode)
            sendEnrichedNowPlaying()
        case .toggleShuffle:
            sp.shuffleMode = (sp.shuffleMode == .off) ? .songs : .off
            sendEnrichedNowPlaying()
        case .seek:
            if let t = cmd.seekTime {
                sp.currentPlaybackTime = t
                sendPosition()
            }
        }
    }

    // MARK: - 진행 위치 송신 (플레이어 측, 1초)
    private var positionTimer: Timer?

    private func startPositionUpdates() {
        stopPositionUpdates()
        guard role == .player else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.sendPosition() }
        RunLoop.main.add(t, forMode: .common)
        positionTimer = t
        sendPosition()
    }

    private func stopPositionUpdates() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func sendPosition() {
        guard role == .player, multipeer.isConnected else { return }
        let sp = MPMusicPlayerController.systemMusicPlayer
        guard let item = sp.nowPlayingItem else { return }
        let dur = item.playbackDuration
        guard dur > 0 else { return }
        let pos = PlaybackPosition(elapsed: sp.currentPlaybackTime,
                                   duration: dur,
                                   isPlaying: sp.playbackState == .playing)
        multipeer.send(Packet(position: pos))
    }

    // MARK: - 곡정보 메타데이터/모드 보강 (플레이어 측)
    private static let releaseYearFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy"; return f
    }()

    /// 작곡가·앨범아티스트·발매일·반복/셔플 모드를 채운다(라이브러리 곡 한정).
    private func enrichNowPlaying(_ msg: NowPlayingMessage) -> NowPlayingMessage {
        var r = msg
        let sp = MPMusicPlayerController.systemMusicPlayer
        if let item = sp.nowPlayingItem {
            r.composer = item.composer
            r.albumArtist = item.albumArtist
            if let date = item.releaseDate {
                r.releaseDate = Self.releaseYearFormatter.string(from: date)
            }
        }
        r.repeatMode = Self.repeatCode(sp.repeatMode)
        r.shuffleMode = (sp.shuffleMode == .off) ? 0 : 1
        return r
    }

    /// 반복/셔플 토글 직후 즉시 갱신된 곡정보를 보낸다(MusicController 중복억제 우회).
    private func sendEnrichedNowPlaying() {
        guard let base = music.current else { return }
        let enriched = enrichNowPlaying(base)
        multipeer.send(Packet(nowPlaying: enriched))
        DispatchQueue.main.async { self.nowPlaying = enriched }
    }

    private static func nextRepeat(_ mode: MPMusicRepeatMode) -> MPMusicRepeatMode {
        switch mode {
        case .none: return .all
        case .all:  return .one
        default:    return .none   // .one, .default → 없음
        }
    }

    private static func repeatCode(_ mode: MPMusicRepeatMode) -> Int {
        switch mode {
        case .one: return 1
        case .all: return 2
        default:   return 0
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
