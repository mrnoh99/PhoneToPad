import Foundation
import MediaPlayer
import AVFoundation
import UIKit

/// 플레이어(아이패드) 측: Apple Music · Apple Music Classical 등
/// 시스템에서 재생 중인 음악을 조종하고 현재 곡 정보를 읽어 콜백으로보낸다.
final class MusicController: ObservableObject {

    @Published var current: NowPlayingMessage?
    /// 곡/재생상태가 바뀌면 호출(네트워크로 전송하는 용도)
    var onNowPlayingChanged: ((NowPlayingMessage) -> Void)?
    /// 사용자가 고른 재생 앱 (Music / Classical)
    var preferredSource: MusicAppSource = .music

    private let player = MPMusicPlayerController.systemMusicPlayer
    private let systemRemote = SystemMediaRemote()
    private var observing = false
    private var pollTimer: Timer?
    private var fastPollTimer: Timer?

    private let artworkPixelSize: CGFloat = 280
    private let artworkJPEGQuality: CGFloat = 0.62

    /// 직전에 실제로 전송한 패킷(동일 내용 중복 전송 방지)
    private var lastSent: NowPlayingMessage?
    /// Classical 앨범아트는 늦게 로드되므로 곡별로 캐시한다.
    private var cachedArtworkJPEG: Data?
    private var cachedArtworkTrackID: String?
    /// publishBurst 지연 호출이 겹치지 않도록 세대 번호로 무효화한다.
    private var burstGeneration = 0

    /// 미디어 라이브러리 권한과 무관하게 곡 관찰을 바로 시작하고, 권한은 병렬로 요청한다.
    func requestAuthAndStart() {
        beginObserving()
        MPMediaLibrary.requestAuthorization { [weak self] _ in
            DispatchQueue.main.async { self?.publishBurst(force: true) }
        }
    }

    private func beginObserving() {
        guard !observing else { publishBurst(force: true); return }
        observing = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(changed),
            name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player)
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed),
            name: .MPMusicPlayerControllerPlaybackStateDidChange, object: player)
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed),
            name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed),
            name: .MPMusicPlayerControllerPlaybackStateDidChange, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(changed),
            name: Notification.Name("MPNowPlayingInfoCenterDefaultNowPlayingInfoDidChange"),
            object: nil)

        systemRemote.onInfoChanged = { [weak self] in
            DispatchQueue.main.async { self?.publishBurst() }
        }
        systemRemote.startObserving()

        if Platform.isMacLike {
            MacNowPlayingFetcher.shared.onUpdated = { [weak self] in
                DispatchQueue.main.async { self?.publishSync(force: true) }
            }
        }

        player.beginGeneratingPlaybackNotifications()
        let pollInterval = Platform.isMacLike ? 1.0 : 2.0
        pollTimer = makeTimer(interval: pollInterval) { [weak self] in
            self?.refreshMacNowPlayingIfNeeded { self?.publishSync() }
        }
        startFastPoll()
        refreshMacNowPlayingIfNeeded { [weak self] in
            self?.systemRemote.refreshNowPlaying {
                DispatchQueue.main.async { self?.publishBurst(force: true) }
            }
        }
        publishBurst(force: true)
    }

    /// 처음 연결·곡 전환 직후 빠르게 메타데이터를 읽는다.
    private func startFastPoll() {
        fastPollTimer?.invalidate()
        let deadline = Date().addingTimeInterval(12)
        fastPollTimer = makeTimer(interval: 0.35) { [weak self] in
            guard let self else { return }
            if Date() >= deadline {
                self.fastPollTimer?.invalidate()
                return
            }
            self.refreshMacNowPlayingIfNeeded {
                self.systemRemote.refreshNowPlaying { [weak self] in
                    DispatchQueue.main.async { self?.publishSync() }
                }
            }
        }
    }

    private func refreshMacNowPlayingIfNeeded(completion: @escaping () -> Void) {
        guard Platform.isMacLike else {
            completion()
            return
        }
        MacNowPlayingFetcher.shared.refresh(completion: completion)
    }

    private func makeTimer(interval: TimeInterval, block: @escaping () -> Void) -> Timer {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in block() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    @objc private func changed() { publishBurst() }

    /// 앱 전환 시 곡 정보를 다시 읽는다 (화면은 유지).
    func invalidateAndRefresh() {
        lastSent = nil
        cachedArtworkJPEG = nil
        cachedArtworkTrackID = nil
        startFastPoll()
        refreshMacNowPlayingIfNeeded { [weak self] in
            self?.systemRemote.refreshNowPlaying {
                DispatchQueue.main.async { self?.publishBurst(force: true) }
            }
        }
        publishBurst(force: true)
    }

    /// 현재 상태를 읽어 @Published 갱신 + (변경됐을 때만) 콜백으로보냄
    func publish(force: Bool = false) {
        applyPublishedMessage(force: force)
        refreshMacNowPlayingIfNeeded { [weak self] in
            self?.systemRemote.refreshNowPlaying {
                DispatchQueue.main.async {
                    self?.applyPublishedMessage(force: force)
                }
            }
        }
    }

    private func applyPublishedMessage(force: Bool = false) {
        let msg = enrichArtwork(bestMessage())
        let playingChanged = msg.isPlaying != lastSent?.isPlaying
        let artworkChanged = msg.artworkJPEG != lastSent?.artworkJPEG
        let metadataChanged = msg.title != lastSent?.title
            || msg.artist != lastSent?.artist
            || msg.album != lastSent?.album
        current = msg
        // 제목·아티스트는 앨범아트보다 먼저 보내 리모컨에 빨리 표시한다.
        if force || metadataChanged || playingChanged || artworkChanged || msg != lastSent {
            lastSent = msg
            onNowPlayingChanged?(msg)
        }
    }

    /// 비동기 갱신 없이 즉시 읽기 (Music 재생/일시정지 직후 UI 반영용)
    private func publishSync(force: Bool = false) {
        applyPublishedMessage(force: force)
    }

    /// Classical 등 시스템 응답 전에 재생/일시정지 아이콘을 바로 바꾼다.
    private func flipPlayingStateOptimistically() {
        guard var msg = current, msg.title != "재생 중인 곡 없음" else { return }
        msg.isPlaying.toggle()
        current = msg
        lastSent = msg
        onNowPlayingChanged?(msg)
    }

    /// 곡이 막 바뀌면 앨범아트가 아직 로드 전이라 한 번만내면 빈/이전 아트가 갈 수 있다.
    func publishBurst(force: Bool = false) {
        burstGeneration += 1
        let generation = burstGeneration
        publish(force: force)
        // Classical 앨범아트는 수 초 뒤에야 채워지는 경우가 많다.
        for delay in [0.05, 0.12, 0.25, 0.5, 1.0, 2.0, 4.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.burstGeneration == generation else { return }
                self.publish()
            }
        }
    }

    private func trackID(for msg: NowPlayingMessage) -> String {
        "\(msg.title)|\(msg.artist)"
    }

    /// 아트가 잠깐 비거나 늦게 오면 같은 곡의 마지막 앨범아트를 유지한다.
    private func enrichArtwork(_ msg: NowPlayingMessage) -> NowPlayingMessage {
        var result = msg
        let id = trackID(for: msg)
        if id != cachedArtworkTrackID {
            cachedArtworkTrackID = id
            if msg.artworkJPEG == nil { cachedArtworkJPEG = nil }
        }
        if let art = msg.artworkJPEG, !art.isEmpty {
            cachedArtworkJPEG = art
        } else if let cached = cachedArtworkJPEG, id == cachedArtworkTrackID {
            result.artworkJPEG = cached
        }
        return result
    }

    // MARK: - 곡 정보 수집 (Music + Classical)

    private func bestMessage() -> NowPlayingMessage {
        let volume = AVAudioSession.sharedInstance().outputVolume
        let fromSystem = messageFromSystemPlayer(volume: volume)
        let fromRemote = systemRemote.currentInfo().flatMap { messageFromInfoDict($0, volume: volume) }
        let fromCenter = MPNowPlayingInfoCenter.default().nowPlayingInfo
            .flatMap { messageFromInfoDict($0, volume: volume) }
        let fromMacScript = MacNowPlayingFetcher.shared.currentInfo()
            .flatMap { messageFromInfoDict($0, volume: volume) }

        // Mac(Tahoe)에서는 osascript → MediaRemote → NowPlayingCenter 순. systemMusicPlayer 는 마지막.
        let order: [NowPlayingMessage?]
        if Platform.isMacLike {
            order = [fromMacScript, fromRemote, fromCenter, fromSystem]
        } else {
            switch preferredSource {
            case .music:
                order = [fromSystem, fromRemote, fromCenter]
            case .classical:
                order = [fromRemote, fromCenter, fromSystem]
            }
        }
        for candidate in order {
            if let msg = candidate, isValidTrack(msg) { return msg }
        }
        return emptyMessage(volume: volume)
    }

    private func isValidTrack(_ msg: NowPlayingMessage) -> Bool {
        !msg.title.isEmpty && msg.title != "재생 중인 곡 없음"
    }

    private func emptyMessage(volume: Float) -> NowPlayingMessage {
        NowPlayingMessage(
            title: "재생 중인 곡 없음",
            artist: "", album: "",
            isPlaying: false, volume: volume,
            artworkJPEG: nil
        )
    }

    private func messageFromSystemPlayer(volume: Float) -> NowPlayingMessage? {
        let item = player.nowPlayingItem
        let isPlaying = (player.playbackState == .playing)

        var artworkData: Data?
        if let artwork = item?.artwork,
           let image = artwork.image(at: CGSize(width: artworkPixelSize, height: artworkPixelSize)) {
            artworkData = jpegData(from: image)
        }

        return NowPlayingMessage(
            title: item?.title ?? "재생 중인 곡 없음",
            artist: item?.artist ?? "",
            album: item?.albumTitle ?? "",
            isPlaying: isPlaying,
            volume: volume,
            artworkJPEG: artworkData
        )
    }

    private func messageFromInfoDict(_ info: [String: Any], volume: Float) -> NowPlayingMessage? {
        let title = stringValue(in: info, keys: [
            SystemMediaRemote.InfoKey.title,
            MPMediaItemPropertyTitle,
            "title", "Name"
        ])
        guard !title.isEmpty else { return nil }

        let artist = stringValue(in: info, keys: [
            SystemMediaRemote.InfoKey.artist,
            MPMediaItemPropertyArtist,
            SystemMediaRemote.InfoKey.composer,
            MPMediaItemPropertyComposer,
            "artist"
        ])
        let album = stringValue(in: info, keys: [
            SystemMediaRemote.InfoKey.album,
            MPMediaItemPropertyAlbumTitle,
            "album"
        ])
        let isPlaying = playbackIsActive(in: info)
        let artworkData = artworkData(from: info)

        return NowPlayingMessage(
            title: title,
            artist: artist,
            album: album,
            isPlaying: isPlaying,
            volume: volume,
            artworkJPEG: artworkData
        )
    }

    private func stringValue(in info: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let s = info[key] as? String, !s.isEmpty { return s }
            if let s = info[key] as? NSString as String?, !s.isEmpty { return s }
        }
        return ""
    }

    private func artworkData(from info: [String: Any]) -> Data? {
        if let artwork = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork,
           let image = artwork.image(at: CGSize(width: artworkPixelSize, height: artworkPixelSize)) {
            return jpegData(from: image)
        }
        let dataKeys = [
            SystemMediaRemote.InfoKey.artworkData,
            "kMRMediaRemoteNowPlayingArtworkData",
            "artwork"
        ]
        for key in dataKeys {
            let raw = (info[key] as? Data) ?? (info[key] as? NSData as Data?)
            guard let raw, !raw.isEmpty else { continue }
            if let ui = UIImage(data: raw) {
                return jpegData(from: ui)
            }
        }
        return nil
    }

    private func jpegData(from image: UIImage) -> Data? {
        image.jpegData(compressionQuality: artworkJPEGQuality)
    }

    /// Now Playing 딕셔너리에서 재생/일시정지 상태를 읽는다.
    private func playbackIsActive(in info: [String: Any]) -> Bool {
        // MPNowPlayingPlaybackState.playing == 1
        if let state = info["MPNowPlayingInfoPropertyPlaybackState"] as? NSNumber {
            return state.intValue == 1
        }
        if let rate = info[SystemMediaRemote.InfoKey.playbackRate] as? Double {
            return rate > 0.01
        }
        if let rate = (info[SystemMediaRemote.InfoKey.playbackRate] as? NSNumber)?.doubleValue {
            return rate > 0.01
        }
        if let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double {
            return rate > 0.01
        }
        if let rate = (info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue {
            return rate > 0.01
        }
        return false
    }

    // MARK: - 명령 (Music · Classical 공통)

    private var useSystemPlayerPath: Bool {
        preferredSource == .music && !Platform.isMacLike
    }

    private func sendPlayback(_ system: () -> Void, remote: SystemMediaRemote.Command) {
        if useSystemPlayerPath {
            system()
        } else if !systemRemote.send(remote) {
            system()
        }
        publishBurst()
    }

    func play() {
        sendPlayback({ player.play() }, remote: .play)
    }

    func pause() {
        sendPlayback({ player.pause() }, remote: .pause)
    }

    func next() {
        sendPlayback({ player.skipToNextItem() }, remote: .nextTrack)
    }

    func prev() {
        sendPlayback({ player.skipToPreviousItem() }, remote: .previousTrack)
    }

    func togglePlayPause() {
        if useSystemPlayerPath {
            if player.playbackState == .playing { player.pause() } else { player.play() }
            publishSync(force: true)
        } else {
            _ = systemRemote.send(.togglePlayPause)
            flipPlayingStateOptimistically()
        }
        publishBurst()
    }

    func publishSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.publish()
        }
    }

    deinit {
        pollTimer?.invalidate()
        fastPollTimer?.invalidate()
        if observing { player.endGeneratingPlaybackNotifications() }
        systemRemote.stopObserving()
        NotificationCenter.default.removeObserver(self)
    }
}
