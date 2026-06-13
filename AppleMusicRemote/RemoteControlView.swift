import SwiftUI
import UIKit

/// 리모컨 모드(아이폰). 곡 정보를 표시하고, 버튼/슬라이더로 명령을 전송한다.
/// 화면 높이에 맞춰 요소 크기를 조절해 iPhone 12 mini 같은 작은 화면에서도 스크롤 없이 들어가게 한다.
struct RemoteControlView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var net: MultipeerService

    @Environment(\.openURL) private var openURL
    @State private var volume: Float = 0.5
    @State private var draggingVolume = false
    /// 탭 직후 재생/일시정지 아이콘을 바로 바꾸기 위한 낙관적 상태
    @State private var playOverride: Bool?

    private var isPlaying: Bool { playOverride ?? app.nowPlaying?.isPlaying ?? false }
    private var shuffleOn: Bool { (app.nowPlaying?.shuffleMode ?? 0) == 1 }
    private var repeatMode: Int { app.nowPlaying?.repeatMode ?? 0 }

    private var statusColor: Color {
        if net.isConnected { return .green }
        if net.statusDetail.contains("연결 중") || net.statusDetail.contains("발견")
            || net.statusDetail.contains("검색") || net.statusDetail.contains("다시") {
            return .orange
        }
        return .red
    }

    var body: some View {
        GeometryReader { geo in
            // 작은 화면(예: 12 mini, 가용 높이 ~730) 감지 후 크기 축소
            let compact = geo.size.height < 740
            let artSize = max(150, min(geo.size.width - 64, geo.size.height * (compact ? 0.32 : 0.40)))
            // Apple Music Now Playing 화면과 유사한 컨트롤 크기
            let playD: CGFloat = compact ? 64 : 72
            let sideD: CGFloat = compact ? 52 : 58
            let playIcon: CGFloat = compact ? 42 : 48
            let sideIcon: CGFloat = compact ? 28 : 32

            ScrollView {
            VStack(spacing: compact ? 8 : 18) {
                // 상태 줄
                VStack(spacing: 4) {
                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)
                        Text(net.isConnected ? "연결됨" : "연결 대기 중…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !net.isConnected {
                            Button {
                                net.rescan()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .font(.footnote)
                        }
                        Button("역할 변경") { app.resetRole() }
                            .font(.footnote)
                    }
                    // 진단: 지금 어느 단계에서 막혀 있는지 보여준다.
                    if !net.isConnected {
                        HStack(spacing: 6) {
                            Text(net.statusDetail)
                                .font(.caption2)
                                .foregroundStyle(net.startFailed ? .red : .secondary)
                                .multilineTextAlignment(.leading)
                            if net.startFailed,
                               let url = URL(string: UIApplication.openSettingsURLString) {
                                Button("설정 열기") { openURL(url) }
                                    .font(.caption2)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                Spacer(minLength: 4)

                if let np = app.nowPlaying,
                   !np.title.isEmpty, np.title != "재생 중인 곡 없음" {
                    VStack(spacing: compact ? 8 : 12) {
                        NowPlayingCard(np: np, artSize: artSize)
                            // 앨범아트 뒤로 포인트 컬러 글로우
                            .background(
                                Circle()
                                    .fill(app.accent)
                                    .frame(width: artSize * 1.15, height: artSize * 1.15)
                                    .blur(radius: 70)
                                    .opacity(0.35)
                            )
                        // 사이공간: 작곡가 / 앨범 아티스트 / 발매일
                        TrackMetaView(np: np, maxWidth: artSize)
                        // 진행바 + 경과/남은 시간 (위치 정보가 도착한 뒤에만 표시)
                        if app.playback != nil {
                            ProgressBar(app: app, accent: app.accent)
                                .frame(maxWidth: artSize)
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(net.isConnected ? "곡 정보를 받는 중…" : "아이패드(Music/Classical) 연결을 기다리는 중")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(height: artSize)
                }

                Spacer(minLength: 4)

                // 재생/볼륨 컨트롤만 연결 전에는 비활성화(상태줄·역할 변경 버튼은 항상 사용 가능)
                Group {
                    // 셔플 | 이전·재생·다음 | 반복  (양 끝에 토글, 가운데 트랜스포트)
                    HStack {
                        Button { app.sendCommand(.toggleShuffle) } label: {
                            Image(systemName: "shuffle")
                                .font(.system(size: compact ? 16 : 18, weight: .semibold))
                                .foregroundStyle(shuffleOn ? app.accent : .secondary)
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 0)

                        HStack(spacing: compact ? 28 : 36) {
                            ControlButton(system: "backward.fill", diameter: sideD, iconSize: sideIcon) {
                                app.sendCommand(.prev)
                            }
                            ControlButton(system: isPlaying ? "pause.fill" : "play.fill",
                                          diameter: playD, iconSize: playIcon) {
                                playOverride = !isPlaying
                                app.sendCommand(.playPause)
                            }
                            ControlButton(system: "forward.fill", diameter: sideD, iconSize: sideIcon) {
                                app.sendCommand(.next)
                            }
                        }
                        .foregroundStyle(app.accent)

                        Spacer(minLength: 0)

                        Button { app.sendCommand(.toggleRepeat) } label: {
                            Image(systemName: repeatMode == 1 ? "repeat.1" : "repeat")
                                .font(.system(size: compact ? 16 : 18, weight: .semibold))
                                .foregroundStyle(repeatMode == 0 ? .secondary : app.accent)
                        }
                        .buttonStyle(.plain)
                    }

                    // 볼륨 슬라이더 — 손잡이는 정원(Circle), 색은 버튼과 동일한 포인트 컬러
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        AccentSlider(value: $volume, accent: app.accent) { editing in
                            draggingVolume = editing
                            if !editing { app.sendVolume(volume) }
                        }
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
                .disabled(!net.isConnected)
                .opacity(net.isConnected ? 1 : 0.4)

                Text("Developed by JaiSung NOH MD · 2026")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, compact ? 16 : 20)
            .padding(.vertical, compact ? 8 : 14)
            // 큰 화면(아이패드)에서는 컨트롤이 과하게 퍼지지 않도록 가운데 적정 폭으로 모은다.
            .frame(maxWidth: 480)
            // 내용이 화면보다 작으면 꽉 채워 중앙 정렬, 크면(큰 글씨 등) 스크롤되도록 minHeight 사용
            .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        // 플레이어가 보내온 볼륨으로 슬라이더 동기화(드래그 중이 아닐 때만)
        .onChange(of: app.nowPlaying?.volume) { _, newValue in
            if let v = newValue, !draggingVolume { volume = v }
        }
        // 아이패드에서 실제 재생 상태가 오면 낙관적 아이콘을 실제 값으로 맞춘다.
        .onChange(of: app.nowPlaying?.isPlaying) { _, _ in
            playOverride = nil
        }
    }
}

/// 볼륨 슬라이더 — Apple Music 스타일: 손잡이 없는 얇은 막대(터치 시 살짝 두꺼워짐).
struct AccentSlider: View {
    @Binding var value: Float           // 0...1
    var accent: Color = .white
    var onEditingChanged: (Bool) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h: CGFloat = dragging ? 11 : 7          // 터치하면 살짝 두꺼워짐
            let clamped = CGFloat(min(max(value, 0), 1))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: h)
                Capsule()
                    .fill(accent)
                    .frame(width: max(h, clamped * w), height: h)
            }
            .frame(width: w, height: 24, alignment: .center)   // 넉넉한 터치 영역
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: dragging)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        onEditingChanged(true)
                        value = Float(min(max(g.location.x / w, 0), 1))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 24)
    }
}

/// 둥근 트랜스포트 버튼 (지름·아이콘 크기 지정 가능)
struct ControlButton: View {
    let system: String
    var diameter: CGFloat = 64
    var iconSize: CGFloat = 38
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: iconSize, weight: .medium))
                .frame(width: diameter, height: diameter)
        }
        .buttonStyle(.plain)
    }
}

/// 앨범 카드와 재생 버튼 사이: 작곡가 / 앨범 아티스트 / 발매일 (있는 항목만)
struct TrackMetaView: View {
    let np: NowPlayingMessage
    var maxWidth: CGFloat = 300

    var body: some View {
        VStack(spacing: 2) {
            if let c = np.composer, !c.isEmpty { row("작곡", c) }
            if let aa = np.albumArtist, !aa.isEmpty, aa != np.artist { row("앨범 아티스트", aa) }
            if let rd = np.releaseDate, !rd.isEmpty { row("발매", rd) }
        }
        .frame(maxWidth: maxWidth)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// 진행바 + 경과/남은 시간. 위치는 1초마다 받고, 그 사이는 로컬에서 보간한다. 드래그로 seek.
struct ProgressBar: View {
    @ObservedObject var app: AppModel
    var accent: Color = .white
    @State private var dragFraction: Double?

    var body: some View {
        let dur = app.playback?.duration ?? 0
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let elapsed = dragFraction.map { $0 * dur } ?? app.currentElapsed()
            let frac = dur > 0 ? min(max(elapsed / dur, 0), 1) : 0
            VStack(spacing: 3) {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22)).frame(height: 6)
                        Capsule().fill(accent).frame(width: max(6, CGFloat(frac) * w), height: 6)
                    }
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                guard dur > 0 else { return }
                                dragFraction = Double(min(max(g.location.x / w, 0), 1))
                            }
                            .onEnded { _ in
                                if let f = dragFraction, dur > 0 { app.sendSeek(to: f * dur) }
                                dragFraction = nil
                            }
                    )
                }
                .frame(height: 22)
                HStack {
                    Text(timeString(elapsed))
                    Spacer()
                    Text("-" + timeString(max(0, dur - elapsed)))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .frame(height: 40)
        .opacity(dur > 0 ? 1 : 0)   // 길이 정보 없으면 숨김
    }

    private func timeString(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
