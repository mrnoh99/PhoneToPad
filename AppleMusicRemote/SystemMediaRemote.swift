import Foundation
import MediaPlayer

/// iOS 시스템 Now Playing 경로(제어 센터·잠금 화면과 동일)로 재생을 제어한다.
/// Apple Music · Apple Music Classical 등 어떤 앱이 재생 중이든 명령을 보낼 수 있다.
final class SystemMediaRemote {

    static let nowPlayingDidChange =
        Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification")
    static let playbackDidChange =
        Notification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")

    /// MediaRemote Now Playing 딕셔너리 키 (Classical 앨범아트 등)
    enum InfoKey {
        static let title = "kMRMediaRemoteNowPlayingInfoTitle"
        static let artist = "kMRMediaRemoteNowPlayingInfoArtist"
        static let album = "kMRMediaRemoteNowPlayingInfoAlbum"
        static let composer = "kMRMediaRemoteNowPlayingInfoComposer"
        static let artworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
        static let artworkMIME = "kMRMediaRemoteNowPlayingInfoArtworkMIMEType"
        static let playbackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    }

    enum Command: UInt32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    /// 시스템 Now Playing 정보가 바뀌면 호출(외부 앱 재생 감지용)
    var onInfoChanged: (() -> Void)?

    private typealias SendCommandFn = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias GetNowPlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias UnregisterFn = @convention(c) () -> Void

    private var sendCommand: SendCommandFn?
    private var getNowPlaying: GetNowPlayingFn?
    private var registerNotifications: RegisterFn?
    private var unregisterNotifications: UnregisterFn?

    private var cachedInfo: [String: Any]?
    private let infoLock = NSLock()

    var isAvailable: Bool { sendCommand != nil }

    init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_NOW
        ) else { return }

        if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommand = unsafeBitCast(sym, to: SendCommandFn.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlaying = unsafeBitCast(sym, to: GetNowPlayingFn.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            registerNotifications = unsafeBitCast(sym, to: RegisterFn.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteUnregisterForNowPlayingNotifications") {
            unregisterNotifications = unsafeBitCast(sym, to: UnregisterFn.self)
        }
    }

    func startObserving() {
        registerNotifications?(DispatchQueue.main)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleNowPlayingNotification),
            name: Self.nowPlayingDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleNowPlayingNotification),
            name: Self.playbackDidChange, object: nil)
        refreshNowPlaying()
    }

    func stopObserving() {
        unregisterNotifications?()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleNowPlayingNotification() {
        refreshNowPlaying()
        onInfoChanged?()
    }

    func refreshNowPlaying(completion: (() -> Void)? = nil) {
        guard let getNowPlaying else {
            completion?()
            return
        }
        getNowPlaying(DispatchQueue.main) { [weak self] dict in
            self?.infoLock.lock()
            self?.cachedInfo = dict as? [String: Any]
            self?.infoLock.unlock()
            completion?()
        }
    }

    func currentInfo() -> [String: Any]? {
        infoLock.lock()
        defer { infoLock.unlock() }
        return cachedInfo
    }

    @discardableResult
    func send(_ command: Command) -> Bool {
        sendCommand?(command.rawValue, nil) ?? false
    }
}
