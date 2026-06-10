import SwiftUI

@main
struct AppleMusicRemoteApp: App {
    @StateObject private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                // 앱이 다시 활성화되면(백그라운드/잠금 복귀) 끊긴 연결을 재시도한다.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { app.multipeer.wakeUp() }
                }
        }
    }
}
