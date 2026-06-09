# PhoneToPad

아이폰으로 **아이패드에서 재생 중인 Apple Music** 을 원격 조종하는 개인용 앱.
재생/일시정지 · 다음곡 · 이전곡 · **볼륨** 조절 + 아이폰 화면에 **현재 곡 정보(제목/아티스트/앨범아트)** 표시.

> 같은 WiFi · 같은 Apple ID 환경 가정. (예: 아이패드 Pro 10.5 / iPadOS 17.7, 아이폰 / iOS 26.5)

## 동작 원리

iOS 에는 "다른 기기의 Music 앱을 네트워크로 원격 조종" 하는 공개 API가 **없습니다.**
그래서 **하나의 유니버설 앱**을 두 기기에 모두 설치하고 역할만 나눕니다.

| 기기 | 역할 | 하는 일 |
|------|------|---------|
| **아이패드** | 플레이어 / 중계 | 받은 명령을 `MPMusicPlayerController.systemMusicPlayer` 로 **실제 Music 앱**에 전달 + 현재 곡 정보 전송 |
| **아이폰** | 리모컨 | 버튼/슬라이더로 명령 전송 + 곡 정보 표시 |

- 두 기기 연결: **MultipeerConnectivity** (같은 WiFi 자동 검색·연결, 외부 서버 불필요)
- 외부 라이브러리 의존성 없음 — 전부 Apple 프레임워크(SwiftUI / MultipeerConnectivity / MediaPlayer / AVFoundation)

## 구성 파일

```
project.yml                       # XcodeGen 스펙
AppleMusicRemote/
  Info.plist                      # 권한 설명 + Bonjour 서비스
  AppleMusicRemoteApp.swift       # @main
  AppModel.swift                  # 전역 상태 + 네트워크/음악/볼륨 연결
  ContentView.swift               # 역할 선택 + 곡 카드(공용)
  PlayerView.swift                # 아이패드 플레이어/중계 화면
  RemoteControlView.swift         # 아이폰 리모컨 화면
  Messages.swift                  # Codable 명령 / 곡정보 패킷
  MultipeerService.swift          # MCSession 송수신
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
3. **두 기기 모두**에 같은 앱을 설치하고 **같은 WiFi** 에 연결.

## 사용법

1. **아이패드**: 앱 실행 → **"이 기기에서 음악 재생 (아이패드)"** 선택
   → 미디어 라이브러리·로컬 네트워크 권한 **허용** → Music 앱에서 플레이리스트 재생 시작.
2. **아이폰**: 앱 실행 → **"리모컨으로 사용 (아이폰)"** 선택.
3. 자동 연결되면(상태 점이 초록) 아이폰에 곡 정보가 뜨고, ⏮ ⏯ ⏭ · 볼륨이 동작합니다.

## 알려진 한계

- **아이패드 앱은 포그라운드로 켜 두세요.** iOS 백그라운드 제약으로 앱이 백그라운드로 가면
  잠시 뒤 연결/명령 수신이 끊길 수 있습니다.
- **볼륨 조절**은 공식 API 가 없어 `MPVolumeView` 내부 슬라이더를 조작하는 비공식 기법을 씁니다.
  개인용/사이드로드에선 동작하지만 향후 OS 업데이트로 깨질 수 있습니다(재생·다음·이전 버튼은 영향 없음).
- 하드웨어 볼륨 버튼으로 바꾼 값은 리모컨에 즉시 반영되지 않을 수 있습니다(다음 곡정보 갱신 시 동기화).

## 비고

개인용 앱이라 App Store 심사 대상이 아닙니다. (`systemMusicPlayer` 원격 조종 컨셉은 심사에서 거절될 수 있음)
