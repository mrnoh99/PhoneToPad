import SwiftUI
import MediaPlayer
import AVFoundation

/// 시스템 볼륨 조절(플레이어=아이패드 측).
/// iOS 에 공식 볼륨 설정 API 가 없어 MPVolumeView 내부 UISlider 를 조작한다.
/// (개인용/사이드로드에서는 동작하나 OS 업데이트로 깨질 수 있는 비공식 기법)
final class VolumeController: ObservableObject {

    /// 화면에 거의 보이지 않게 올려 두는 볼륨 뷰
    let volumeView = MPVolumeView(frame: CGRect(x: -3000, y: -3000, width: 100, height: 30))

    private var slider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    var currentVolume: Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    func setVolume(_ value: Float) {
        let v = max(0, min(1, value))
        // 슬라이더가 뷰 계층에 붙은 뒤 동작하므로 짧게 지연
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.slider?.value = v
            self.slider?.sendActions(for: .valueChanged)
        }
    }

    func changeVolume(by delta: Float) {
        setVolume(currentVolume + delta)
    }
}

/// MPVolumeView 를 SwiftUI 뷰 계층에 (거의 안 보이게) 얹어 슬라이더가 작동하도록 함.
struct VolumeMountView: UIViewRepresentable {
    let controller: VolumeController
    func makeUIView(context: Context) -> MPVolumeView {
        let view = controller.volumeView
        view.alpha = 0.001
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
