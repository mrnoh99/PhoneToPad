import SwiftUI
import UIKit

/// 플레이어 모드(주로 아이패드). 리모컨 명령은 AppModel 이 수신해 MusicController 로 실행한다.
///
/// 리모컨과 동일한 **앨범 표지 카드 + 트랜스포트/볼륨 컨트롤** UI. 로컬에서 직접 제어도 가능하다.
struct PlayerView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var music: MusicController
    @ObservedObject var net: MultipeerService

    @State private var volume: Float = 0.5
    @State private var draggingVolume = false
    @State private var playOverride: Bool?

    private var isPlaying: Bool { playOverride ?? music.current?.isPlaying ?? false }

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
            let compact = geo.size.height < 740
            let artSize = max(180, min(geo.size.width - 96, geo.size.height * (compact ? 0.34 : 0.44)))
            let playD: CGFloat = compact ? 58 : 64
            let sideD: CGFloat = compact ? 46 : 50
            let playIcon: CGFloat = compact ? 34 : 38
            let sideIcon: CGFloat = compact ? 26 : 28

            ScrollView {
            VStack(spacing: compact ? 10 : 20) {
                statusRow

                MusicSourcePicker(app: app)

                Spacer(minLength: 4)

                if let np = music.current, !np.title.isEmpty, np.title != "재생 중인 곡 없음" {
                    NowPlayingCard(np: np, artSize: artSize)
                        // 앨범아트 뒤로 포인트 컬러 글로우 (리모컨과 동일)
                        .background(
                            Circle()
                                .fill(app.accent)
                                .frame(width: artSize * 1.15, height: artSize * 1.15)
                                .blur(radius: 70)
                                .opacity(0.35)
                        )
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note")
                            .font(.system(size: 48, weight: .thin))
                            .foregroundStyle(.secondary)
                        Text(net.isConnected
                             ? "\(app.musicSource.label) 앱에서 재생을 시작하세요"
                             : "리모컨(아이폰) 연결을 기다리는 중")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(height: artSize)
                }

                Spacer(minLength: 4)

                // 로컬 음악/볼륨을 직접 제어하는 컨트롤(네트워크 전송이 아님)
                transportControls(compact: compact, playD: playD, sideD: sideD,
                                  playIcon: playIcon, sideIcon: sideIcon)
                volumeControls(compact: compact)

                Text("Developed by JaiSung NOH MD · 2026")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, compact ? 16 : 24)
            .padding(.vertical, compact ? 8 : 16)
            // UI 폭을 앨범아트 너비에 맞춰 좁힌다(컨트롤·제목이 앨범 사진 폭을 넘지 않도록).
            .frame(maxWidth: artSize)
            .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        // 플레이어가 읽은 실제 볼륨으로 슬라이더 동기화(드래그 중이 아닐 때만)
        .onChange(of: music.current?.volume) { _, newValue in
            if let v = newValue, !draggingVolume { volume = v }
        }
        .onChange(of: music.current?.isPlaying) { _, _ in
            playOverride = nil
        }
        // 볼륨 제어용 MPVolumeView 를 (거의 안 보이게) 뷰 계층에 얹는다.
        .background(
            VolumeMountView(controller: app.volume)
                .frame(width: 1, height: 1)
        )
        // 플레이어/중계 화면이 떠 있는 동안엔 화면 자동 잠금을 끈다.
        // (화면이 꺼지면 앱이 백그라운드로 가 MultipeerConnectivity 연결이 끊기기 때문)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            volume = music.current?.volume ?? app.volume.currentVolume
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// 트랜스포트 버튼 (로컬 systemMusicPlayer 직접 제어)
    private func transportControls(compact: Bool, playD: CGFloat, sideD: CGFloat,
                                   playIcon: CGFloat, sideIcon: CGFloat) -> some View {
        HStack(spacing: compact ? 16 : 20) {
            ControlButton(system: "backward.fill", diameter: sideD, iconSize: sideIcon) {
                music.prev()
            }
            ControlButton(system: isPlaying ? "pause.fill" : "play.fill",
                          diameter: playD, iconSize: playIcon) {
                playOverride = !isPlaying
                music.togglePlayPause()
            }
            .foregroundStyle(.white)
            ControlButton(system: "forward.fill", diameter: sideD, iconSize: sideIcon) {
                music.next()
            }
        }
    }

    /// 볼륨 슬라이더 + 미세 조정 버튼 (로컬 볼륨 직접 제어)
    private func volumeControls(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 14) {
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $volume, in: 0...1) { editing in
                    draggingVolume = editing
                    app.volume.setVolume(volume)
                }
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            HStack(spacing: 36) {
                Button { app.volume.changeVolume(by: -0.0625) } label: {
                    Image(systemName: "minus.circle.fill")
                }
                Button { app.volume.changeVolume(by: 0.0625) } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
            .font(compact ? .title2 : .title)
            .foregroundStyle(.tint)
        }
    }

    /// 상단 연결 상태 줄: [연결점] 상태 텍스트 ……… [재검색] [역할 변경]
    private var statusRow: some View {
        VStack(spacing: 4) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(net.isConnected
                     ? "리모컨 연결됨 · \(app.musicSource.label)"
                     : "연결 대기 중… · \(app.musicSource.label)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if !net.isConnected {
                    Button { net.rescan() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .font(.footnote)
                }
                Button("역할 변경") { app.resetRole() }
                    .font(.footnote)
            }
            if !net.isConnected {
                HStack(spacing: 6) {
                    Text(net.statusDetail)
                        .font(.caption2)
                        .foregroundStyle(net.startFailed ? .red : .secondary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
