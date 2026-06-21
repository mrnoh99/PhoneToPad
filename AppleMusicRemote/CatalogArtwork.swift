import Foundation
import UIKit
import MusicKit

/// 제목·아티스트로 카탈로그를 조회해 **앨범아트 + 상세 메타데이터**를 받아온다.
///
/// **하이브리드**: MusicKit(정확·풍부) 우선 → 실패하면 iTunes Search API(인증 불필요) 폴백.
/// 결과는 곡별로 캐시한다. 공개 메서드는 메인 스레드에서 호출하고 completion 도 메인으로 돌려준다.
final class CatalogArtworkFetcher {
    static let shared = CatalogArtworkFetcher()

    struct Result { var artwork: Data?; var info: CatalogInfo? }

    private var cache: [String: Result] = [:]
    private var inFlight: Set<String> = []
    private let pixel = 600

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy. M. d."; return f
    }()

    private func key(_ title: String, _ artist: String, _ album: String) -> String {
        "\(title)|\(artist)|\(album)".lowercased()
    }

    /// 캐시에 있으면 즉시, 없으면 비동기로 받아 completion(메인) 호출.
    func lookup(title: String, artist: String, album: String,
                completion: @escaping (Result) -> Void) {
        guard !title.isEmpty else { completion(Result()); return }
        let k = key(title, artist, album)
        if let r = cache[k] { completion(r); return }
        guard !inFlight.contains(k) else { completion(Result()); return }   // 중복 요청 방지
        inFlight.insert(k)
        let pixel = self.pixel
        Task {
            let result = await Self.fetch(title: title, artist: artist, album: album, pixel: pixel)
            await MainActor.run {
                self.inFlight.remove(k)
                if result.artwork != nil || result.info != nil { self.cache[k] = result }
                completion(result)
            }
        }
    }

    private static func fetch(title: String, artist: String, album: String, pixel: Int) async -> Result {
        if let r = await fetchFromMusicKit(title: title, artist: artist, pixel: pixel),
           (r.artwork != nil || r.info != nil) {
            return r
        }
        return await fetchFromITunes(title: title, artist: artist, pixel: pixel) ?? Result()
    }

    // MARK: - MusicKit (정확·풍부; App ID에 MusicKit 활성화 + 구독 필요)

    private static func fetchFromMusicKit(title: String, artist: String, pixel: Int) async -> Result? {
        var status = MusicAuthorization.currentStatus
        if status == .notDetermined { status = await MusicAuthorization.request() }
        guard status == .authorized else { return nil }
        do {
            let term = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = 15
            let response = try await request.response()
            guard let song = bestMusicKitMatch(response.songs, title: title, artist: artist) else { return nil }

            var info = CatalogInfo(source: "MusicKit")
            info.workName = song.workName
            info.movementName = song.movementName
            info.movementNumber = song.movementNumber
            info.movementCount = song.movementCount
            info.composerName = song.composerName
            info.genres = song.genreNames.isEmpty ? nil : song.genreNames
            info.albumTitle = song.albumTitle
            info.trackNumber = song.trackNumber
            info.discNumber = song.discNumber
            info.durationSeconds = song.duration
            if let d = song.releaseDate { info.releaseDate = dateFormatter.string(from: d) }
            info.isExplicit = (song.contentRating == .explicit)
            info.isrc = song.isrc
            info.appleMusicURL = song.url?.absoluteString

            var art: Data?
            if let url = song.artwork?.url(width: pixel, height: pixel),
               let (data, _) = try? await URLSession.shared.data(from: url) {
                art = UIImage(data: data)?.jpegData(compressionQuality: 0.85) ?? data
            }
            return Result(artwork: art, info: info)
        } catch {
            return nil
        }
    }

    private static func bestMusicKitMatch(_ songs: MusicItemCollection<Song>,
                                          title: String, artist: String) -> Song? {
        let t = title.lowercased(), a = artist.lowercased()
        let scored = songs.map { song -> (Song, Int) in
            (song, score(candidateTitle: song.title, candidateArtist: song.artistName, t: t, a: a))
        }
        return scored.max(by: { $0.1 < $1.1 })?.0 ?? songs.first
    }

    // MARK: - iTunes Search API (인증 불필요 폴백)

    private static func fetchFromITunes(title: String, artist: String, pixel: Int) async -> Result? {
        let term = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
        guard var comps = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15")
        ]
        if let region = Locale.current.region?.identifier {
            comps.queryItems?.append(URLQueryItem(name: "country", value: region))
        }
        guard let url = comps.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(ITunesResponse.self, from: data)
            guard let best = bestITunesMatch(response.results, title: title, artist: artist) else { return nil }

            var info = CatalogInfo(source: "iTunes")
            info.composerName = best.composerName
            info.genres = best.primaryGenreName.map { [$0] }
            info.albumTitle = best.collectionName
            info.trackNumber = best.trackNumber
            info.discNumber = best.discNumber
            if let ms = best.trackTimeMillis { info.durationSeconds = Double(ms) / 1000 }
            if let rd = best.releaseDate, let d = ISO8601DateFormatter().date(from: rd) {
                info.releaseDate = dateFormatter.string(from: d)
            }
            info.isExplicit = best.trackExplicitness == "explicit"
            info.appleMusicURL = best.trackViewUrl

            var art: Data?
            if let artURL = best.artworkURL(size: pixel),
               let (imgData, _) = try? await URLSession.shared.data(from: artURL) {
                art = UIImage(data: imgData)?.jpegData(compressionQuality: 0.85) ?? imgData
            }
            return Result(artwork: art, info: info)
        } catch {
            return nil
        }
    }

    private static func bestITunesMatch(_ tracks: [ITunesTrack], title: String, artist: String) -> ITunesTrack? {
        let t = title.lowercased(), a = artist.lowercased()
        let scored = tracks.map { track -> (ITunesTrack, Int) in
            (track, score(candidateTitle: track.trackName ?? "", candidateArtist: track.artistName ?? "", t: t, a: a))
        }
        return scored.max(by: { $0.1 < $1.1 })?.0 ?? tracks.first
    }

    // MARK: - 매칭 점수 (공통)

    private static func score(candidateTitle: String, candidateArtist: String, t: String, a: String) -> Int {
        var s = 0
        let ct = candidateTitle.lowercased()
        if ct == t { s += 3 } else if !ct.isEmpty, ct.contains(t) || t.contains(ct) { s += 1 }
        let ca = candidateArtist.lowercased()
        if ca == a { s += 2 } else if !a.isEmpty, ca.contains(a) || a.contains(ca) { s += 1 }
        return s
    }
}

private struct ITunesResponse: Decodable {
    let results: [ITunesTrack]
}

private struct ITunesTrack: Decodable {
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let composerName: String?
    let primaryGenreName: String?
    let trackNumber: Int?
    let discNumber: Int?
    let trackTimeMillis: Int?
    let releaseDate: String?
    let trackExplicitness: String?
    let trackViewUrl: String?
    let artworkUrl100: String?

    /// 100x100 썸네일 URL을 원하는 해상도로 바꾼다.
    func artworkURL(size: Int) -> URL? {
        guard let s = artworkUrl100 else { return nil }
        let big = s.replacingOccurrences(of: "100x100bb", with: "\(size)x\(size)bb")
                   .replacingOccurrences(of: "100x100", with: "\(size)x\(size)")
        return URL(string: big)
    }
}
