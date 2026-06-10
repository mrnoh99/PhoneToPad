import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        switch app.role {
        case .unset:
            RolePickerView()
        case .player:
            PlayerView(music: app.music, net: app.multipeer)
        case .remote:
            RemoteControlView(app: app, net: app.multipeer)
        }
    }
}

/// 첫 실행 시 이 기기의 역할을 고른다.
struct RolePickerView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 60))
                .foregroundStyle(.pink)
            Text("PhoneToPad")
                .font(.largeTitle.bold())
            Text("이 기기의 역할을 선택하세요")
                .foregroundStyle(.secondary)

            // 페어링 코드(PIN): 두 기기에 같은 값을 입력하면 그 둘끼리만 연결된다.
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    TextField("페어링 코드 (선택)", text: $app.pairingCode)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 200)
                }
                Text("두 기기에 같은 코드를 입력하세요. 비워두면 같은 앱끼리 연결됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            VStack(spacing: 14) {
                Button {
                    app.startPlayer()
                } label: {
                    Label("이 기기에서 음악 재생 (아이패드)", systemImage: "ipad")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    app.startRemote()
                } label: {
                    Label("리모컨으로 사용 (아이폰)", systemImage: "iphone")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 32)

            Spacer()
            Text("두 기기를 같은 WiFi 에 두고, 아이패드에서 '음악 재생', 아이폰에서 '리모컨' 을 고르세요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()

            Text("Developed by JaiSung NOH MD · 2026")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}

/// 현재 곡 카드(앨범아트 + 제목/아티스트) — 양쪽에서 공용
struct NowPlayingCard: View {
    let np: NowPlayingMessage

    var body: some View {
        VStack(spacing: 12) {
            if let data = np.artworkJPEG, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 260, height: 260)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                    )
            }
            Text(np.title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            if !np.artist.isEmpty {
                Text(np.artist).foregroundStyle(.secondary)
            }
            if !np.album.isEmpty {
                Text(np.album).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
