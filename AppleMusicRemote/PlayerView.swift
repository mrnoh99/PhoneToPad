import SwiftUI

/// 플레이어/중계 모드(아이패드). Music 앱에서 재생 중인 곡을 보여주고,
/// 리모컨이 보낸 명령을 systemMusicPlayer 로 실행한다(AppModel 에서 처리).
struct PlayerView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var music: MusicController
    @ObservedObject var net: MultipeerService

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Circle()
                    .fill(net.isConnected ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(net.isConnected
                     ? "리모컨 연결됨 (\(net.connectedPeerNames.joined(separator: ", ")))"
                     : "리모컨 연결 대기 중…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("역할 변경") { app.resetRole() }
                    .font(.footnote)
            }

            Text("재생 / 중계 모드")
                .font(.title2.bold())

            Divider()

            Spacer()
            if let np = music.current {
                NowPlayingCard(np: np)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Music 앱에서 플레이리스트 재생을 시작하세요")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            Text("이 화면을 켜 둔 채로 두세요.\n앱이 백그라운드로 가면 잠시 후 연결이 끊길 수 있습니다.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
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
}
