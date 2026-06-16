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
        let apply: ([String: Any]?) -> Void = { [weak self] info in
            self?.infoLock.lock()
            self?.cachedInfo = info
            self?.infoLock.unlock()
            completion?()
        }
        guard let getNowPlaying else {
            apply(fallbackNowPlayingInfo())
            return
        }
        getNowPlaying(DispatchQueue.main) { [weak self] dict in
            let parsed = dict as? [String: Any]
            if let parsed, Self.hasTrackMetadata(parsed) {
                apply(parsed)
                return
            }
            apply(self?.fallbackNowPlayingInfo() ?? parsed)
        }
    }

    func currentInfo() -> [String: Any]? {
        infoLock.lock()
        defer { infoLock.unlock() }
        if let cachedInfo, Self.hasTrackMetadata(cachedInfo) { return cachedInfo }
        if let fallback = fallbackNowPlayingInfo() {
            cachedInfo = fallback
            return fallback
        }
        return cachedInfo
    }

    /// Mac(Catalyst / iOS-on-Mac)에서는 systemMusicPlayer 대신 MediaRemote 경로가 필요하다.
    /// macOS 15.4+ 에서 GetNowPlayingInfo 가 비면 MRNowPlayingRequest 로 한 번 더 시도한다.
    private func fallbackNowPlayingInfo() -> [String: Any]? {
        guard Platform.isMacLike else { return nil }
        return Self.fetchViaNowPlayingRequest()
    }

    private static func hasTrackMetadata(_ info: [String: Any]) -> Bool {
        let titleKeys = [InfoKey.title, MPMediaItemPropertyTitle, "title", "Name"]
        return titleKeys.contains { key in
            guard let value = info[key] as? String else { return false }
            return !value.isEmpty
        }
    }

    private static func ensureMediaRemoteLoaded() {
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    }

    private static func fetchViaNowPlayingRequest() -> [String: Any]? {
        ensureMediaRemoteLoaded()
        guard let requestClass = NSClassFromString("MRNowPlayingRequest") as? NSObject.Type else { return nil }
        let itemSelector = NSSelectorFromString("localNowPlayingItem")
        guard requestClass.responds(to: itemSelector),
              let item = requestClass.perform(itemSelector)?.takeUnretainedValue() as? NSObject
        else { return nil }

        let infoSelector = NSSelectorFromString("nowPlayingInfo")
        guard item.responds(to: infoSelector),
              let infoObject = item.perform(infoSelector)?.takeUnretainedValue()
        else { return nil }

        if let dict = infoObject as? [String: Any], Self.hasTrackMetadata(dict) { return dict }
        if let dict = (infoObject as? NSDictionary) as? [String: Any], Self.hasTrackMetadata(dict) { return dict }
        return nil
    }

    @discardableResult
    func send(_ command: Command) -> Bool {
        sendCommand?(command.rawValue, nil) ?? false
    }
}
