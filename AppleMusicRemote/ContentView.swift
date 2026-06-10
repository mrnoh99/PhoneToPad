import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()   // 미니멀 블랙 베이스
            roleContent
        }
        .preferredColorScheme(.dark)        // 항상 다크 모드
        .tint(app.accent)                   // 앨범아트에서 추출한 포인트 컬러
    }

    @ViewBuilder private var roleContent: some View {
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
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.white)
            Text("PhoneToPad")
                .font(.largeTitle.weight(.semibold))
                .tracking(1)
            Text("이 기기의 역할을 선택하세요")
                .foregroundStyle(.secondary)

            // 페어링 코드(PIN): 두 기기에 같은 값을 입력하면 그 둘끼리만 연결된다.
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("페어링 코드 (선택)", text: $app.pairingCode)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 200)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .background(Color.white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                Text("두 기기에 같은 코드를 입력하세요. 비워두면 같은 앱끼리 연결됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            VStack(spacing: 12) {
                RoleButton(title: "이 기기에서 음악 재생 (아이패드)",
                           systemImage: "ipad", filled: true) { app.startPlayer() }
                RoleButton(title: "리모컨으로 사용 (아이폰)",
                           systemImage: "iphone", filled: false) { app.startRemote() }
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

/// 현재 곡 카드(앨범아트 + 제목/아티스트) — 양쪽에서 공용. artSize 로 앨범아트 크기를 조절.
struct NowPlayingCard: View {
    let np: NowPlayingMessage
    var artSize: CGFloat = 260

    var body: some View {
        VStack(spacing: 12) {
            if let data = np.artworkJPEG, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: artSize, maxHeight: artSize)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: artSize, height: artSize)
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 44, weight: .thin))
                            .foregroundStyle(.secondary)
                    )
            }
            Text(np.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if !np.artist.isEmpty {
                Text(np.artist).foregroundStyle(.secondary)
            }
            if !np.album.isEmpty {
                Text(np.album).font(.footnote).foregroundStyle(.tertiary)
            }
        }
    }
}

/// 역할 선택용 미니멀 버튼 — 채움(흰색) 또는 외곽선(다크) 두 스타일
private struct RoleButton: View {
    let title: String
    let systemImage: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(filled ? Color.black : Color.white)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(filled ? Color.white : Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(filled ? 0 : 0.18), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
