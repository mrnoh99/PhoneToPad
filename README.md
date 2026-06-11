# PhoneToPad

아이폰으로 **아이패드에서 재생 중인 Apple Music** 을 원격 조종하는 개인용 앱.
재생/일시정지 · 다음곡 · 이전곡 · **볼륨** 조절 + 아이폰 화면에 **현재 곡 정보(제목/아티스트/앨범아트)** 표시.

> 근거리(같은 WiFi 권장) 환경 가정. (예: 아이패드 Pro 10.5 / iPadOS 17.7, 아이폰 / iOS 26.5)
> 연결 자체에는 같은 Apple ID 가 **필요 없습니다**(같은 Apple ID 는 Apple Music 콘텐츠 공유용).

## 동작 원리

iOS 에는 "다른 기기의 Music 앱을 네트워크로 원격 조종" 하는 공개 API가 **없습니다.**
그래서 **하나의 유니버설 앱**을 두 기기에 모두 설치하고 역할만 나눕니다.

| 기기 | 역할 | 하는 일 |
|------|------|---------|
| **아이패드** | 플레이어 / 중계 | 받은 명령을 `MPMusicPlayerController.systemMusicPlayer` 로 **실제 Music 앱**에 전달 + 현재 곡 정보 전송 |
| **아이폰** | 리모컨 | 버튼/슬라이더로 명령 전송 + 곡 정보 표시 |

- 두 기기 연결: **MultipeerConnectivity** (근거리 자동 검색·연결, 외부 서버 불필요)
- 외부 라이브러리 의존성 없음 — 전부 Apple 프레임워크(SwiftUI / MultipeerConnectivity / MediaPlayer / AVFoundation / CryptoKit)

### 화면 구성 (역할별로 다름)
- **아이패드(플레이어/중계)**: 화면을 거의 차지하지 않는 **최상단 한 줄 상태바**. Music 앱을
  전체화면(또는 Split View)으로 쓰면서 위에 얇은 바만 얹어 두는 용도.
- **아이폰/아이패드(리모컨)**: **전체화면 풀 리모컨 UI**(앨범아트 + 트랜스포트 + 볼륨). 어느 기기에서
  리모컨을 골라도 동일하게 동작합니다.

### 연결 경로 & 페어링
- **전송 경로**: MultipeerConnectivity 가 **인프라 WiFi + P2P WiFi(AWDL) + Bluetooth** 를 자동 병행합니다.
  "같은 WiFi 전용"이 아니며, WiFi+Bluetooth 가 켜져 있으면 공유기 없이도 붙을 수 있습니다.
  다만 **앨범아트 전송 때문에 WiFi 가 사실상 필수** → 두 기기 모두 **같은 WiFi + Bluetooth ON** 권장.
- **페어링 코드(PIN)**: 역할 선택 화면에서 두 기기에 **같은 코드**를 입력하면 그 둘끼리만 연결됩니다.
  - 코드는 그대로 방송하지 않고 **SHA256 해시**로 변환해 토큰으로 사용(원문 노출 최소화).
  - 비워두면 "같은 앱끼리" 연결됩니다(집에 기기가 여러 대면 코드를 지정하세요).
- **역할 페어링**: `player ↔ remote` 처럼 역할이 보완될 때만 연결(둘 다 같은 역할이면 무시).
- **자동 재연결**: 연결이 끊기면 잠시 후 자동으로 재탐색·재연결하고, 앱이 다시 활성화될 때도 재시도합니다.
- 세션은 `.required` 암호화로 보호됩니다.

## 구성 파일

```
project.yml                       # XcodeGen 스펙
AppleMusicRemote/
  Info.plist                      # 권한 설명 + Bonjour 서비스
  AppleMusicRemoteApp.swift       # @main
  AppModel.swift                  # 전역 상태 + 네트워크/음악/볼륨 연결
  ContentView.swift               # 역할 선택(+페어링 코드 입력) + 곡 카드(공용)
  PlayerView.swift                # 아이패드 플레이어/중계 화면(최상단 한 줄 바)
  RemoteControlView.swift         # 리모컨 화면(전체화면 풀 UI)
  Messages.swift                  # Codable 명령 / 곡정보 패킷
  MultipeerService.swift          # MCSession 송수신 + 페어링 코드/역할 매칭/자동 재연결
  MusicController.swift           # systemMusicPlayer 제어 + 곡정보 관찰
  VolumeController.swift          # MPVolumeView 볼륨 조작
```

## 빌드 & 설치

1. **XcodeGen 설치 후 프로젝트 생성**
   ```sh
   brew install xcodegen
   cd PhoneToPad
   xcodegen generate          # PhoneToPad.xcodeproj 생성
   open PhoneToPad.xcodeproj
   ```
2. **서명**: Signing & Capabilities 에서 본인 Apple ID 팀 선택
   (무료 계정 = 7일마다 재설치 / 유료 계정 = 1년)
   - 빌드엔 **iOS 26 SDK 지원 Xcode(=Xcode 26.x)** 필요(아이폰 26.5 설치용).
   - Deployment Target 은 **iOS 17.0** (아이패드 17.7 도 설치 가능).
3. **두 기기 모두**에 같은 앱을 설치하고 **같은 WiFi + Bluetooth ON**.

## 사용법

1. **(선택) 페어링 코드**: 두 기기의 역할 선택 화면에서 **같은 코드**(예: `1234`)를 입력.
   집에 기기가 여러 대거나 확실히 내 기기끼리만 묶고 싶을 때 사용합니다(비워도 됨).
2. **아이패드**: 재생 앱(**Music / Classical**)을 고르고 **"이 기기에서 음악 재생"** 선택
   → 미디어 라이브러리·로컬 네트워크 권한 **허용** → 해당 앱에서 재생 시작.
   (안정적인 동시 사용은 아래 **Slide Over 권장** 참고.)
3. **아이폰**: **"리모컨으로 사용 (아이폰)"** 선택.
4. 자동 연결되면(상태 점이 초록) 아이폰에 곡 정보가 뜨고, ⏮ ⏯ ⏭ · 볼륨이 동작합니다.
   연결이 끊겨도 자동으로 다시 연결을 시도합니다.

## 아이패드 연결 유지 — Slide Over 권장 ✅

아이패드에서 Music/Classical 앱과 **함께** 쓰면서 연결을 끊기지 않게 하려면
**Split View 가 아니라 Slide Over** 로 PhoneToPad 를 띄우세요.

| 방식 | 동작 | 연결 유지 |
|------|------|-----------|
| **Slide Over** (권장) | PhoneToPad 를 **떠 있는 패널**로, Music 은 뒤 전체화면 | ✅ 잘 유지됨 |
| Split View | 두 앱을 나란히 분할 | ⚠️ Music 을 만지면 끊길 수 있음 |

**왜 그런가** — iOS 는 화면 자동 잠금 해제(`isIdleTimerDisabled`)를 **그 순간 활성(`foregroundActive`)인 앱**의 설정만 적용합니다.
- **Split View**: Music 을 터치하는 순간 PhoneToPad 가 `foregroundInactive` 가 되어 "자동 잠금 끄기"가 무시됨 → 시간이 지나면 화면이 꺼지고 앱이 백그라운드로 가 연결이 끊깁니다.
- **Slide Over**: PhoneToPad 패널이 앞에 떠 있는 동안 **계속 활성**으로 유지되어 자동 잠금이 차단됨 → 앱이 살아있고 연결도 유지됩니다. 뒤의 Music 은 `systemMusicPlayer` 라 비활성이어도 재생이 계속됩니다.

> 주의: Slide Over 패널을 **화면 밖으로 밀어 숨기면** PhoneToPad 가 백그라운드로 가 끊깁니다. 패널은 보이게 두세요.

## 알려진 한계

- **아이패드 앱은 포그라운드(활성)로 켜 두세요.** iOS 백그라운드 제약으로 앱이 백그라운드로 가면
  잠시 뒤 연결/명령 수신이 끊길 수 있습니다. 플레이어 화면은 자동 잠금을 끄고(끊겨도 자동 재연결),
  아래 **Slide Over 권장** 방식을 쓰면 가장 안정적입니다.
- **볼륨 조절**은 공식 API 가 없어 `MPVolumeView` 내부 슬라이더를 조작하는 비공식 기법을 씁니다.
  개인용/사이드로드에선 동작하지만 향후 OS 업데이트로 깨질 수 있습니다(재생·다음·이전 버튼은 영향 없음).
- 하드웨어 볼륨 버튼으로 바꾼 값은 리모컨에 즉시 반영되지 않을 수 있습니다(다음 곡정보 갱신 시 동기화).

## 비고

개인용 앱이라 App Store 심사 대상이 아닙니다. (`systemMusicPlayer` 원격 조종 컨셉은 심사에서 거절될 수 있음)

---

<sub>Developed by JaiSung NOH MD · 2026</sub>
