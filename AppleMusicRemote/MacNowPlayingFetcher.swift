import Foundation
import MediaPlayer
#if targetEnvironment(macCatalyst)
import OSAKit
import UIKit
#endif

/// macOS Tahoe(15.4+) 에서 앱 프로세스 내부 MediaRemote 는 차단된다.
/// Mac Catalyst 빌드에서는 osascript / NSAppleScript 로 Now Playing 정보를 읽는다.
final class MacNowPlayingFetcher {

    static let shared = MacNowPlayingFetcher()

    var onUpdated: (() -> Void)?

    private let queue = DispatchQueue(label: "com.mrnoh99.phonetopad.mac-nowplaying", qos: .utility)
    private var cachedInfo: [String: Any]?
    private var isFetching = false
    private var lastFetch = Date.distantPast
    private let minInterval: TimeInterval = 0.9

    private init() {}

    func currentInfo() -> [String: Any]? {
        cachedInfo
    }

    func refresh(completion: (() -> Void)? = nil) {
        guard Platform.isMacLike else {
            completion?()
            return
        }
        #if targetEnvironment(macCatalyst)
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion?() }
                return
            }
            let now = Date()
            let canFetchMetadata = now.timeIntervalSince(self.lastFetch) >= self.minInterval && !self.isFetching

            if canFetchMetadata {
                self.isFetching = true
                self.lastFetch = now
                defer { self.isFetching = false }

                guard var info = Self.fetchViaOsascript() ?? Self.fetchViaMusicAppleScript() else {
                    DispatchQueue.main.async { completion?() }
                    return
                }
                Self.attachArtworkIfMissing(&info)
                DispatchQueue.main.async {
                    if Self.hasTrackMetadata(info) {
                        self.cachedInfo = info
                        self.onUpdated?()
                    }
                    completion?()
                }
                return
            }

            if var cached = self.cachedInfo, Self.hasTrackMetadata(cached), !Self.hasArtwork(in: cached) {
                Self.attachArtworkIfMissing(&cached)
                DispatchQueue.main.async {
                    if Self.hasArtwork(in: cached) {
                        self.cachedInfo = cached
                        self.onUpdated?()
                    }
                    completion?()
                }
                return
            }

            DispatchQueue.main.async { completion?() }
        }
        #else
        completion?()
        #endif
    }

    private static func hasTrackMetadata(_ info: [String: Any]) -> Bool {
        let keys = [
            SystemMediaRemote.InfoKey.title,
            MPMediaItemPropertyTitle,
            "title"
        ]
        return keys.contains { key in
            guard let value = info[key] as? String else { return false }
            return !value.isEmpty
        }
    }

    private static func hasArtwork(in info: [String: Any]) -> Bool {
        let data = (info[SystemMediaRemote.InfoKey.artworkData] as? Data)
            ?? (info[SystemMediaRemote.InfoKey.artworkData] as? NSData as Data?)
        return data?.isEmpty == false
    }

    #if targetEnvironment(macCatalyst)
    private static let jxaScript = """
    function run() {
        var bundle = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
        if (!bundle) { return JSON.stringify({}); }
        bundle.load;
        var MRNowPlayingRequest = $.NSClassFromString('MRNowPlayingRequest');
        if (!MRNowPlayingRequest) { return JSON.stringify({}); }
        var item = MRNowPlayingRequest.localNowPlayingItem;
        if (!item) { return JSON.stringify({}); }
        var infoDict = item.nowPlayingInfo;
        if (!infoDict) { return JSON.stringify({}); }
        function str(k) {
            var v = infoDict.objectForKey(k);
            return v ? String(v.js) : '';
        }
        function num(k) {
            var v = infoDict.objectForKey(k);
            return v ? Number(v.js) : 0;
        }
        return JSON.stringify({
            kMRMediaRemoteNowPlayingInfoTitle: str('kMRMediaRemoteNowPlayingInfoTitle'),
            kMRMediaRemoteNowPlayingInfoArtist: str('kMRMediaRemoteNowPlayingInfoArtist'),
            kMRMediaRemoteNowPlayingInfoAlbum: str('kMRMediaRemoteNowPlayingInfoAlbum'),
            kMRMediaRemoteNowPlayingInfoPlaybackRate: num('kMRMediaRemoteNowPlayingInfoPlaybackRate')
        });
    }
    """

    /// JXA + MRNowPlayingRequest — Tahoe 26.x 에서 osascript 프로세스 권한으로 동작
    private static func fetchViaOsascript() -> [String: Any]? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonetopad-np-\(UUID().uuidString).js")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        do {
            try jxaScript.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        guard let output = runOsascript(arguments: ["-l", "JavaScript", tempURL.path]),
              let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              hasTrackMetadata(json)
        else { return nil }
        return json
    }

    /// Music 앱 Apple Events — 프로세스 내 NSAppleScript (Process/popen 불필요)
    private static func fetchViaMusicAppleScript() -> [String: Any]? {
        let script = """
        tell application "Music"
            if player state is not stopped then
                set t to current track
                set trackName to name of t
                set trackArtist to artist of t
                set trackAlbum to album of t
                set playingNow to (player state is playing)
                return trackName & tab & trackArtist & tab & trackAlbum & tab & playingNow
            end if
        end tell
        return ""
        """
        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&error),
              let output = descriptor.stringValue,
              !output.isEmpty
        else { return nil }

        return parseMusicScriptOutput(output)
    }

    /// JXA/MRNowPlayingRequest 는 Tahoe 에서 앨범아트 바이너리를 못 넘긴다.
    /// 메타데이터와 동일하게 osascript 서브프로세스로 Music 에서 파일 저장 후 읽는다.
    private static func attachArtworkIfMissing(_ info: inout [String: Any]) {
        if hasArtwork(in: info) { return }
        guard let jpeg = fetchMusicArtworkJPEG() else { return }
        info[SystemMediaRemote.InfoKey.artworkData] = jpeg
    }

    private static func fetchMusicArtworkJPEG() -> Data? {
        let token = UUID().uuidString
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonetopad-art-\(token).scpt")
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let script = """
        set outPath to (POSIX path of (path to temporary items folder)) & "phonetopad-art-\(token).img"
        tell application "Music"
            if player state is not stopped then
                if (count of artworks of current track) > 0 then
                    set artData to raw data of artwork 1 of current track
                    set outFile to open for access POSIX file outPath with write permission
                    set eof outFile to 0
                    write artData to outFile
                    close access outFile
                    return outPath
                end if
            end if
        end tell
        return ""
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        guard let path = runOsascript(arguments: [scriptURL.path]),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path),
              let raw = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return nil }
        defer { try? FileManager.default.removeItem(atPath: path) }

        if let jpeg = UIImage(data: raw)?.jpegData(compressionQuality: 0.62), !jpeg.isEmpty {
            return jpeg
        }
        return raw.isEmpty ? nil : raw
    }

    private static func parseMusicScriptOutput(_ output: String) -> [String: Any]? {
        let parts = output.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, !parts[0].isEmpty else { return nil }

        let isPlaying = parts[3].lowercased() == "true"
        return [
            SystemMediaRemote.InfoKey.title: parts[0],
            SystemMediaRemote.InfoKey.artist: parts[1],
            SystemMediaRemote.InfoKey.album: parts[2],
            SystemMediaRemote.InfoKey.playbackRate: isPlaying ? 1.0 : 0.0
        ]
    }

    /// Swift Process/popen 대신 C 브릿지 — Mac Catalyst 에서 컴파일 가능
    private static func runOsascript(arguments: [String]) -> String? {
        let argv = ["/usr/bin/osascript"] + arguments
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        for arg in argv {
            guard let cString = strdup(arg) else { return nil }
            cStrings.append(cString)
        }
        defer { cStrings.forEach { free($0) } }

        return cStrings.withUnsafeBufferPointer { buffer -> String? in
            guard let base = buffer.baseAddress else { return nil }
            guard let raw = PhoneToPadRunOsascript(base, Int32(cStrings.count)) else { return nil }
            defer { free(raw) }
            return String(cString: raw)
        }
    }
    #endif
}
