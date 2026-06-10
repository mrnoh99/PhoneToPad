import SwiftUI

/// 플레이어/중계 모드(아이패드). 리모컨이 보낸 명령을 systemMusicPlayer 로 실행한다(AppModel 에서 처리).
///
/// 아이패드에서는 이 앱이 "배경 릴레이" 역할만 하면 되므로 화면을 일부러 작고 단순하게 구성한다.
/// 보통은 Music 앱과 Split View 로 나란히 띄워 좁은 폭에서 쓰는 것을 가정 → 컴팩트 레이아웃.
struct PlayerView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var music: MusicController
    @ObservedObject var net: MultipeerService

    var body: some View {
        VStack(spacing: 12) {
            // 상태 줄 (연결 표시 + 역할 변경)
            HStack(spacing: 6) {
                Circle()
                    .fill(net.isConnected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(net.isConnected ? "리모컨 연결됨" : "연결 대기 중…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("역할") { app.resetRole() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }

            // 현재 곡 — 한 줄짜리 컴팩트 행 (작은 썸네일 + 제목/아티스트)
            CompactNowPlayingRow(np: music.current)

            // 백그라운드 유지 안내 (아주 작게)
            Text("Music 앱과 나란히(Split View) 두면 연결이 유지됩니다.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(12)
        // 콘텐츠 폭을 좁게 고정해 큰 화면에서도 작은 패널처럼 보이게 한다.
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

/// 아이패드 플레이어용: 작은 썸네일 + 제목/아티스트를 한 줄에 담은 컴팩트 카드
private struct CompactNowPlayingRow: View {
    let np: NowPlayingMessage?

    var body: some View {
        HStack(spacing: 10) {
            artwork
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(np?.title ?? "재생 중인 곡 없음")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let artist = np?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            if let np {
                Image(systemName: np.isPlaying ? "play.fill" : "pause.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var artwork: some View {
        if let data = np?.artworkJPEG, let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFill()
        } else {
            ZStack {
                Color.gray.opacity(0.2)
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
