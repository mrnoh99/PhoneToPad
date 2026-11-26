import SwiftUI

/// Now Playing 화면의 가사 버튼 줄. 가사가 있을 때만 누를 수 있다.
struct LyricsButtonRow: View {
    @ObservedObject var app: AppModel
    let action: () -> Void

    private var available: Bool { !(app.lyrics?.isEmpty ?? true) }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                Label("가사", systemImage: "quote.bubble")
                    .font(.footnote.weight(.semibold))
                    .padding(.vertical, 7)
                    .padding(.horizontal, 14)
                    .foregroundStyle(available ? app.accent : .secondary)
                    .background(Color.white.opacity(available ? 0.1 : 0.04), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!available)

            if app.lyricsLoading {
                ProgressView().controlSize(.mini)
            } else if !available, app.nowPlaying != nil {
                Text("가사 없음").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 가사 창. 시간 정보가 있으면 현재 줄을 강조·자동 스크롤하고, 줄을 탭하면 그 위치로 이동한다.
struct LyricsSheet: View {
    @ObservedObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                // 앨범 포인트 컬러를 은은하게 깔아 Now Playing 과 톤을 맞춘다.
                LinearGradient(colors: [app.accent.opacity(0.35), .black],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                content
            }
            .navigationTitle(app.nowPlaying?.title ?? "가사")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title3)
                    }
                    .accessibilityLabel("닫기")
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(app.accent)
    }

    @ViewBuilder private var content: some View {
        if let lyrics = app.lyrics, !lyrics.isEmpty {
            VStack(spacing: 0) {
                if let artist = app.nowPlaying?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                }
                if let synced = lyrics.synced {
                    SyncedLyricsView(app: app, lines: synced)
                } else {
                    ScrollView {
                        Text(lyrics.plain ?? "")
                            .font(.title3.weight(.medium))
                            .lineSpacing(8)
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(24)
                    }
                }
                Text("가사 제공: \(lyrics.source)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            }
        } else if app.lyricsLoading {
            ProgressView("가사를 찾는 중…")
        } else {
            VStack(spacing: 10) {
                Image(systemName: "quote.bubble").font(.system(size: 40, weight: .thin))
                Text("이 곡의 가사를 찾지 못했습니다.").font(.subheadline)
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// 시간 동기 가사: 재생 위치(리모컨 보간값)에 맞춰 현재 줄을 강조한다.
private struct SyncedLyricsView: View {
    @ObservedObject var app: AppModel
    let lines: [LyricLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                TimelineView(.periodic(from: .now, by: 0.3)) { _ in
                    let current = currentIndex(at: app.currentElapsed())
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(lines) { line in
                            let isCurrent = line.id == current
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.3))
                                .scaleEffect(isCurrent ? 1.0 : 0.97, anchor: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { app.sendSeek(to: line.time) }   // 그 줄로 이동
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 40)
                    .animation(.easeOut(duration: 0.25), value: current)
                    .onChange(of: current) { _, new in
                        guard let new else { return }
                        withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(new, anchor: .center) }
                    }
                    .onAppear {
                        if let current { proxy.scrollTo(current, anchor: .center) }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// 현재 시각 이전에 시작한 마지막 줄
    private func currentIndex(at time: Double) -> Int? {
        guard app.playback != nil else { return nil }
        return lines.last { $0.time <= time + 0.25 }?.id
    }
}
