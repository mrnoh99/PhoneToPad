import SwiftUI

/// 리모컨 모드(아이폰). 곡 정보를 표시하고, 버튼/슬라이더로 명령을 전송한다.
struct RemoteControlView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var net: MultipeerService

    @State private var volume: Float = 0.5
    @State private var draggingVolume = false

    private var isPlaying: Bool { app.nowPlaying?.isPlaying ?? false }

    var body: some View {
        VStack(spacing: 20) {
            // 상태 줄
            HStack {
                Circle()
                    .fill(net.isConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(net.isConnected ? "연결됨" : "연결 대기 중…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("역할 변경") { app.resetRole() }
                    .font(.footnote)
            }

            Spacer()

            if let np = app.nowPlaying {
                NowPlayingCard(np: np)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(net.isConnected ? "곡 정보를 받는 중…" : "아이패드(플레이어) 연결을 기다리는 중")
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // 트랜스포트 버튼
            HStack(spacing: 44) {
                ControlButton(system: "backward.fill") { app.sendCommand(.prev) }
                ControlButton(system: isPlaying ? "pause.fill" : "play.fill", big: true) {
                    app.sendCommand(.playPause)
                }
                ControlButton(system: "forward.fill") { app.sendCommand(.next) }
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

            // 볼륨 미세 조정 버튼
            HStack(spacing: 36) {
                Button { app.sendCommand(.volumeDown) } label: {
                    Image(systemName: "minus.circle.fill")
                }
                Button { app.sendCommand(.volumeUp) } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
            .font(.title)
            .foregroundStyle(.tint)
            .padding(.bottom, 8)
        }
        .padding()
        // 아이폰/아이패드 어디서 리모컨으로 쓰든 전체화면을 채우되,
        // 큰 화면(아이패드)에서는 컨트롤이 과하게 퍼지지 않도록 가운데 적정 폭으로 모은다.
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(!net.isConnected)
        .opacity(net.isConnected ? 1 : 0.6)
        // 플레이어가 보내온 볼륨으로 슬라이더 동기화(드래그 중이 아닐 때만)
        .onChange(of: app.nowPlaying?.volume) { _, newValue in
            if let v = newValue, !draggingVolume { volume = v }
        }
    }
}

/// 큰 둥근 트랜스포트 버튼
struct ControlButton: View {
    let system: String
    var big: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: big ? 54 : 38, weight: .medium))
                .frame(width: big ? 88 : 64, height: big ? 88 : 64)
        }
        .buttonStyle(.plain)
    }
}
