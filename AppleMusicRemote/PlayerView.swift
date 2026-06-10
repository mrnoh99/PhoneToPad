import SwiftUI

/// 플레이어/중계 모드(아이패드). 리모컨이 보낸 명령을 systemMusicPlayer 로 실행한다(AppModel 에서 처리).
///
/// 아이패드에서는 이 앱이 "배경 릴레이" 역할만 하면 되므로 화면을 **최상단 한 줄 바**로 최소화한다.
/// (Music 앱을 전체화면으로 쓰면서 위쪽에 얇은 상태바만 얹는 사용을 가정)
struct PlayerView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var music: MusicController
    @ObservedObject var net: MultipeerService

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Spacer(minLength: 0)   // 나머지 공간은 비워 둠 → 화면을 거의 차지하지 않는 얇은 바
        }
        // 볼륨 제어용 MPVolumeView 를 (거의 안 보이게) 뷰 계층에 얹는다.
        .background(
            VolumeMountView(controller: app.volume)
                .frame(width: 1, height: 1)
        )
        // 플레이어/중계 화면이 떠 있는 동안엔 화면 자동 잠금을 끈다.
        // (화면이 꺼지면 앱이 백그라운드로 가 MultipeerConnectivity 연결이 끊기기 때문)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// 최상단 한 줄 상태바: [연결점] 제목·아티스트 [재생아이콘] ……… [역할]
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(net.isConnected ? Color.green : Color.gray)
                .frame(width: 7, height: 7)

            Text(trackLine)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)

            if let np = music.current {
                Image(systemName: np.isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Button("역할") { app.resetRole() }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)   // 시스템 바 머티리얼 (얇은 상태바 느낌)
    }

    /// 한 줄에 들어갈 "제목 · 아티스트" 문자열
    private var trackLine: String {
        guard let np = music.current else {
            return net.isConnected ? "리모컨 연결됨 · 재생 중인 곡 없음" : "리모컨 연결 대기 중…"
        }
        return np.artist.isEmpty ? np.title : "\(np.title) · \(np.artist)"
    }
}
