import Foundation

/// 한 줄의 싱크 가사
struct LyricLine: Equatable, Identifiable {
    var id: Int            // 줄 번호
    var time: Double       // 시작 시각(초)
    var text: String
}

/// 현재 곡의 가사
struct Lyrics: Equatable {
    var plain: String?             // 일반 가사
    var synced: [LyricLine]?       // 시간 정보가 있는 가사(있으면 현재 줄 강조)
    var source: String             // "곡 내장 가사" / "LRCLIB"

    var isEmpty: Bool { (plain?.isEmpty ?? true) && (synced?.isEmpty ?? true) }
}

/// 가사 조회: ① 곡에 내장된 가사(플레이어가 보내옴) → ② LRCLIB(lrclib.net, 인증 불필요한 공개 가사 DB).
/// Apple Music 스트리밍 가사는 공개 API 가 없어 가져올 수 없으므로 LRCLIB 로 보완한다.
final class LyricsService {
    static let shared = LyricsService()

    private var cache: [String: Lyrics?] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        // LRCLIB 는 클라이언트 식별용 User-Agent 를 요청한다(일반적인 앱 이름만 보냄)
        config.httpAdditionalHeaders = ["User-Agent": "PhoneToPad/1.0"]
        return config.urlSession
    }()

    private init() {}

    static func key(title: String, artist: String) -> String {
        "\(title)|\(artist)".lowercased()
    }

    /// 캐시에 있으면 즉시 반환. 없으면 LRCLIB 에서 찾는다. (nil = 가사 없음)
    @MainActor
    func lyrics(title: String, artist: String, album: String, duration: Double?) async -> Lyrics? {
        let k = Self.key(title: title, artist: artist)
        if let cached = cache[k] { return cached }
        let result = await fetchLRCLIB(title: title, artist: artist, album: album, duration: duration)
        cache[k] = result
        return result
    }

    // MARK: - LRCLIB

    private struct Record: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private func fetchLRCLIB(title: String, artist: String, album: String, duration: Double?) async -> Lyrics? {
        // ① 정확 조회: 제목 + 아티스트 (+ 앨범/길이)
        var params = ["track_name": title, "artist_name": artist]
        if !album.isEmpty { params["album_name"] = album }
        if let d = duration, d > 0 { params["duration"] = String(Int(d.rounded())) }
        if let r: Record = await get("https://lrclib.net/api/get", params), let l = Self.lyrics(from: r) {
            return l
        }
        // ② 앨범/길이 없이 다시 정확 조회
        if params.count > 2,
           let r: Record = await get("https://lrclib.net/api/get", ["track_name": title, "artist_name": artist]),
           let l = Self.lyrics(from: r) {
            return l
        }
        // ③ 검색: 제목+아티스트 → 제목만. 길이가 가장 가까운 결과 선택
        for q in [["track_name": title, "artist_name": artist], ["q": "\(title) \(artist)"], ["track_name": title]] {
            guard let list: [Record] = await get("https://lrclib.net/api/search", q) else { continue }
            let candidates = list.filter { Self.lyrics(from: $0) != nil }
            let best = candidates.min { a, b in
                abs((a.duration ?? 0) - (duration ?? 0)) < abs((b.duration ?? 0) - (duration ?? 0))
            }
            // 길이를 알면 ±8초 이내만 같은 곡으로 인정(엉뚱한 가사 방지)
            if let best, duration == nil || abs((best.duration ?? 0) - (duration ?? 0)) <= 8,
               let l = Self.lyrics(from: best) {
                return l
            }
        }
        return nil
    }

    private func get<T: Decodable>(_ base: String, _ params: [String: String]) async -> T? {
        guard var comps = URLComponents(string: base) else { return nil }
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func lyrics(from r: Record) -> Lyrics? {
        if r.instrumental == true { return nil }
        let synced = r.syncedLyrics.map(parseLRC) ?? []
        let plain = r.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = Lyrics(plain: (plain?.isEmpty ?? true) ? nil : plain,
                       synced: synced.isEmpty ? nil : synced,
                       source: "LRCLIB")
        return l.isEmpty ? nil : l
    }

    /// "[mm:ss.xx] 가사" 형식 파싱
    static func parseLRC(_ text: String) -> [LyricLine] {
        var lines: [(Double, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var times: [Double] = []
            // 한 줄에 여러 타임태그가 붙을 수 있다: [00:12.00][00:45.10]가사
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) {
                    times.append(m * 60 + s)
                }
                rest = rest[rest.index(after: close)...]
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for t in times { lines.append((t, words)) }
        }
        return lines.sorted { $0.0 < $1.0 }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}

private extension URLSessionConfiguration {
    var urlSession: URLSession { URLSession(configuration: self) }
}
