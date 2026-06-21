import Foundation
import MusicKit
import UIKit

/// 스트리밍 곡처럼 시스템(systemMusicPlayer / MediaRemote)에서 앨범아트를 못 얻을 때,
/// Apple Music 카탈로그에서 제목·아티스트로 검색해 아트워크를 받아오는 폴백.
/// 결과는 곡별로 캐시한다. (MusicKit 권한 + Apple Music 구독 + 네트워크 필요)
///
/// 공개 메서드는 메인 스레드에서 호출하고, completion 도 메인 스레드로 돌려준다.
final class CatalogArtworkFetcher {
    static let shared = CatalogArtworkFetcher()

    private var cache: [String: Data] = [:]
    private var inFlight: Set<String> = []
    private let pixel = 600

    private func key(_ title: String, _ artist: String, _ album: String) -> String {
        "\(title)|\(artist)|\(album)".lowercased()
    }

    /// 캐시에 있으면 즉시, 없으면 비동기로 받아 completion(메인) 호출(실패 시 nil).
    func artwork(title: String, artist: String, album: String,
                 completion: @escaping (Data?) -> Void) {
        guard !title.isEmpty else { completion(nil); return }
        let k = key(title, artist, album)
        if let d = cache[k] { completion(d); return }
        guard !inFlight.contains(k) else { completion(nil); return }   // 같은 곡 중복 요청 방지
        inFlight.insert(k)
        Task {
            let data = await Self.fetch(title: title, artist: artist, album: album, pixel: pixel)
            await MainActor.run {
                self.inFlight.remove(k)
                if let data { self.cache[k] = data }
                completion(data)
            }
        }
    }

    private static func fetch(title: String, artist: String, album: String, pixel: Int) async -> Data? {
        var status = MusicAuthorization.currentStatus
        if status == .notDetermined { status = await MusicAuthorization.request() }
        guard status == .authorized else { return nil }
        do {
            let term = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = 10
            let response = try await request.response()
            guard let song = bestMatch(response.songs, title: title, artist: artist),
                  let url = song.artwork?.url(width: pixel, height: pixel) else { return nil }
            let (data, _) = try await URLSession.shared.data(from: url)
            if let ui = UIImage(data: data) { return ui.jpegData(compressionQuality: 0.7) }
            return data
        } catch {
            return nil
        }
    }

    /// 제목·아티스트가 가장 잘 맞는 곡을 고른다.
    private static func bestMatch(_ songs: MusicItemCollection<Song>,
                                  title: String, artist: String) -> Song? {
        let t = title.lowercased(), a = artist.lowercased()
        let scored = songs.map { song -> (Song, Int) in
            var score = 0
            let st = song.title.lowercased()
            if st == t { score += 3 } else if st.contains(t) || t.contains(st) { score += 1 }
            let sa = song.artistName.lowercased()
            if sa == a { score += 2 } else if !a.isEmpty, sa.contains(a) || a.contains(sa) { score += 1 }
            return (song, score)
        }
        return scored.max(by: { $0.1 < $1.1 })?.0 ?? songs.first
    }
}
