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
            let playD: CGFloat = compact ? 72 : 88
            let sideD: CGFloat = compact ? 58 : 64
            let playIcon: CGFloat = compact ? 44 : 54
            let sideIcon: CGFloat = compact ? 34 : 38

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
                    NowPlayingCard(np: np, artSize: artSize)
                        // 앨범아트 뒤로 포인트 컬러 글로우
                        .background(
                            Circle()
                                .fill(app.accent)
                                .frame(width: artSize * 1.15, height: artSize * 1.15)
                                .blur(radius: 70)
                                .opacity(0.35)
                        )
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
                    // 트랜스포트 버튼 (가운데 재생 버튼만 포인트 컬러)
                    HStack(spacing: compact ? 36 : 44) {
                        ControlButton(system: "backward.fill", diameter: sideD, iconSize: sideIcon) {
                            app.sendCommand(.prev)
                        }
                        ControlButton(system: isPlaying ? "pause.fill" : "play.fill",
                                      diameter: playD, iconSize: playIcon) {
                            playOverride = !isPlaying
                            app.sendCommand(.playPause)
                        }
                        .foregroundStyle(.white)
                        ControlButton(system: "forward.fill", diameter: sideD, iconSize: sideIcon) {
                            app.sendCommand(.next)
                        }
                    }

                    // 볼륨 슬라이더
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $volume, in: 0...1) { editing in
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
