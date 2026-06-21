import Foundation
import UIKit

/// 스트리밍 곡처럼 시스템(systemMusicPlayer / MediaRemote)에서 앨범아트를 못 얻을 때,
/// **iTunes Search API**(공개, 인증·구독·App ID 불필요)로 제목·아티스트를 검색해
/// 앨범아트를 받아오는 폴백. 결과는 곡별로 캐시한다. (네트워크만 필요)
///
/// 공개 메서드는 메인 스레드에서 호출하고, completion 도 메인 스레드로 돌려준다.
final class CatalogArtworkFetcher {
    static let shared = CatalogArtworkFetcher()

    private var cache: [String: Data] = [:]
    private var inFlight: Set<String> = []

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
            let data = await Self.fetch(title: title, artist: artist, album: album)
            await MainActor.run {
                self.inFlight.remove(k)
                if let data { self.cache[k] = data }
                completion(data)
            }
        }
    }

    private static func fetch(title: String, artist: String, album: String) async -> Data? {
        let term = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
        guard var comps = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10")
        ]
        if let region = Locale.current.region?.identifier {
            comps.queryItems?.append(URLQueryItem(name: "country", value: region))
        }
        guard let url = comps.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(ITunesResponse.self, from: data)
            guard let best = bestMatch(response.results, title: title, artist: artist),
                  let artURL = best.highResArtworkURL else { return nil }
            let (imgData, _) = try await URLSession.shared.data(from: artURL)
            if let ui = UIImage(data: imgData) { return ui.jpegData(compressionQuality: 0.8) }
            return imgData
        } catch {
            return nil
        }
    }

    /// 제목·아티스트가 가장 잘 맞는 결과를 고른다.
    private static func bestMatch(_ tracks: [ITunesTrack], title: String, artist: String) -> ITunesTrack? {
        let t = title.lowercased(), a = artist.lowercased()
        let scored = tracks.map { track -> (ITunesTrack, Int) in
            var score = 0
            let tt = (track.trackName ?? "").lowercased()
            if tt == t { score += 3 } else if !tt.isEmpty, tt.contains(t) || t.contains(tt) { score += 1 }
            let ta = (track.artistName ?? "").lowercased()
            if ta == a { score += 2 } else if !a.isEmpty, ta.contains(a) || a.contains(ta) { score += 1 }
            return (track, score)
        }
        return scored.max(by: { $0.1 < $1.1 })?.0 ?? tracks.first
    }
}

private struct ITunesResponse: Decodable {
    let results: [ITunesTrack]
}

private struct ITunesTrack: Decodable {
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let artworkUrl100: String?

    /// 100x100 썸네일 URL을 600x600 고해상도로 바꾼다.
    var highResArtworkURL: URL? {
        guard let s = artworkUrl100 else { return nil }
        let big = s.replacingOccurrences(of: "100x100bb", with: "600x600bb")
                   .replacingOccurrences(of: "100x100", with: "600x600")
        return URL(string: big)
    }
}
