import SwiftUI
import UIKit

/// 플레이어 모드(주로 아이패드). 리모컨 명령은 AppModel 이 수신해 MusicController 로 실행한다.
///
/// 리모컨과 동일한 **앨범 표지 카드 + 트랜스포트/볼륨 컨트롤** UI. 로컬에서 직접 제어도 가능하다.
struct PlayerView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var music: MusicController
    @ObservedObject var net: MultipeerService

    @Environment(\.openURL) private var openURL
    @State private var volume: Float = 0.5
    @State private var draggingVolume = false
    @State private var playOverride: Bool?

    private var isPlaying: Bool { playOverride ?? music.current?.isPlaying ?? false }
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
            let compact = geo.size.height < 740
            let artSize = max(150, min(geo.size.width - 96, geo.size.height * (compact ? 0.28 : 0.36)))
            // 아이패드 화면 높이에 맞도록 컨트롤을 작게(리모컨보다 작음)
            let playD: CGFloat = compact ? 48 : 54
            let sideD: CGFloat = compact ? 40 : 44
            let playIcon: CGFloat = compact ? 30 : 34
            let sideIcon: CGFloat = compact ? 22 : 24

            ScrollView {
            VStack(spacing: compact ? 6 : 10) {
                statusRow

                MusicSourcePicker(app: app)

                Spacer(minLength: 0)

                if let np = app.nowPlaying, !np.title.isEmpty, np.title != "재생 중인 곡 없음" {
                    VStack(spacing: compact ? 8 : 12) {
                        NowPlayingCard(np: np, artSize: artSize)
                            // 앨범아트 뒤로 포인트 컬러 글로우 (리모컨과 동일)
                            .background(
                                Circle()
                                    .fill(app.accent)
                                    .frame(width: artSize * 1.15, height: artSize * 1.15)
                                    .blur(radius: 70)
                                    .opacity(0.35)
                            )
                        // 사이공간: 카탈로그 상세(+가사) 또는 시스템 메타데이터
                        if np.catalog != nil || np.lyrics?.isEmpty == false {
                            CatalogInfoView(info: np.catalog, lyrics: np.lyrics, maxWidth: artSize)
                        } else {
                            TrackMetaView(np: np, maxWidth: artSize)
                        }
                        // 진행바 + 경과/남은 시간 (위치 정보가 있을 때만 표시)
                        if app.playback != nil {
                            ProgressBar(app: app, accent: app.accent)
                                .frame(maxWidth: artSize)
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note")
                            .font(.system(size: 48, weight: .thin))
                            .foregroundStyle(.secondary)
                        if Platform.needsMacCatalystForNowPlaying {
                            Text("Mac 플레이어는 Xcode에서 My Mac (Mac Catalyst)로 실행해야 곡 정보를 읽을 수 있습니다.")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                        } else {
                            Text(net.isConnected
                                 ? "\(app.musicSource.label) 앱에서 재생을 시작하세요"
                                 : "리모컨(아이폰) 연결을 기다리는 중")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(height: artSize)
                }

                Spacer(minLength: 0)

                // 로컬 음악/볼륨을 직접 제어하는 컨트롤(네트워크 전송이 아님).
                transportControls(compact: compact, playD: playD, sideD: sideD,
                                  playIcon: playIcon, sideIcon: sideIcon)
                volumeControls(compact: compact)

                Text("Developed by JaiSung NOH MD · 2026")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, compact ? 16 : 20)
            .padding(.vertical, compact ? 8 : 14)
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

    /// 셔플 | 이전·재생·다음 | 반복 (리모컨 하단과 동일 구성, 로컬 직접 제어)
    private func transportControls(compact: Bool, playD: CGFloat, sideD: CGFloat,
                                   playIcon: CGFloat, sideIcon: CGFloat) -> some View {
        HStack {
            Button { app.togglePlayerShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: compact ? 16 : 18, weight: .semibold))
                    .foregroundStyle(shuffleOn ? app.accent : .secondary)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            HStack(spacing: compact ? 12 : 16) {
                ControlButton(system: "backward.fill", diameter: sideD, iconSize: sideIcon) {
                    music.prev()
                }
                ControlButton(system: isPlaying ? "pause.fill" : "play.fill",
                              diameter: playD, iconSize: playIcon) {
                    playOverride = !isPlaying
                    music.togglePlayPause()
                }
                ControlButton(system: "forward.fill", diameter: sideD, iconSize: sideIcon) {
                    music.next()
                }
            }
            .foregroundStyle(app.accent)

            Spacer(minLength: 0)

            Button { app.togglePlayerRepeat() } label: {
                Image(systemName: repeatMode == 1 ? "repeat.1" : "repeat")
                    .font(.system(size: compact ? 16 : 18, weight: .semibold))
                    .foregroundStyle(repeatMode == 0 ? .secondary : app.accent)
            }
            .buttonStyle(.plain)
        }
    }

    /// 볼륨 슬라이더 (리모컨과 동일: AccentSlider, +/- 버튼 없음 / 로컬 직접 제어)
    private func volumeControls(compact: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            AccentSlider(value: $volume, accent: app.accent) { editing in
                draggingVolume = editing
                if !editing { app.volume.setVolume(volume) }
            }
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
    }

    /// 상단 연결 상태 줄: [연결점] 상태 텍스트 ……… [재검색] [역할 변경]
    private var statusRow: some View {
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
                    if net.startFailed,
                       let url = URL(string: UIApplication.openSettingsURLString) {
                        Button("설정 열기") { openURL(url) }
                            .font(.caption2)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
