import Foundation

enum Platform {
    static var isCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    /// Designed for iPad 로 Mac 에서 실행 중이면 곡 정보 API 가 Tahoe 에서 차단된다.
    static var needsMacCatalystForNowPlaying: Bool {
        isMacLike && !isCatalyst
    }

    /// iOS 앱을 Mac에서 실행(Catalyst / Designed for iPad)하는 환경
    static var isMacLike: Bool {
        #if os(macOS)
        return true
        #elseif targetEnvironment(macCatalyst)
        return true
        #else
        if #available(iOS 14.0, *) {
            return ProcessInfo.processInfo.isiOSAppOnMac
        }
        return false
        #endif
    }
}
