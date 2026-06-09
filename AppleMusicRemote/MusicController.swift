import Foundation
import MediaPlayer
import AVFoundation
import UIKit

/// 플레이어(아이패드) 측: 실제 Music 앱의 재생 큐를 조종하고,
/// 현재 곡 정보를 읽어 콜백으로 내보낸다.
final class MusicController: ObservableObject {

    @Published var current: NowPlayingMessage?
    /// 곡/재생상태가 바뀌면 호출(네트워크로 전송하는 용도)
    var onNowPlayingChanged: ((NowPlayingMessage) -> Void)?

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var observing = false

    /// 미디어 라이브러리 권한을 요청한 뒤 재생 알림 관찰을 시작
    func requestAuthAndStart() {
        MPMediaLibrary.requestAuthorization { [weak self] _ in
            DispatchQueue.main.async { self?.beginObserving() }
        }
    }

    private func beginObserving() {
        guard !observing else { publish(); return }
        observing = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed),
            name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player)
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed),
            name: .MPMusicPlayerControllerPlaybackStateDidChange, object: player)
        player.beginGeneratingPlaybackNotifications()
        publish()
    }

    @objc private func changed() { publish() }

    /// 현재 상태를 읽어 @Published + 콜백으로 내보냄
    func publish() {
        let item = player.nowPlayingItem
        let isPlaying = (player.playbackState == .playing)
        let volume = AVAudioSession.sharedInstance().outputVolume

        var artworkData: Data?
        if let artwork = item?.artwork,
           let image = artwork.image(at: CGSize(width: 300, height: 300)) {
            artworkData = image.jpegData(compressionQuality: 0.7)
        }

        let msg = NowPlayingMessage(
            title: item?.title ?? "재생 중인 곡 없음",
            artist: item?.artist ?? "",
            album: item?.albumTitle ?? "",
            isPlaying: isPlaying,
            volume: volume,
            artworkJPEG: artworkData
        )
        current = msg
        onNowPlayingChanged?(msg)
    }

    // MARK: - 명령
    func play()            { player.play();                publishSoon() }
    func pause()           { player.pause();               publishSoon() }
    func next()            { player.skipToNextItem();       publishSoon() }
    func prev()            { player.skipToPreviousItem();   publishSoon() }
    func togglePlayPause() {
        if player.playbackState == .playing { player.pause() } else { player.play() }
        publishSoon()
    }

    /// 명령 직후엔 상태 반영이 약간 늦으므로 살짝 지연 후 publish
    func publishSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.publish()
        }
    }

    deinit {
        if observing { player.endGeneratingPlaybackNotifications() }
        NotificationCenter.default.removeObserver(self)
    }
}
