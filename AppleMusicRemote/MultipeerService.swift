import Foundation
import MultipeerConnectivity
import UIKit
import CryptoKit

/// 같은 WiFi/근거리의 두 기기를 자동으로 찾아 연결하고, Packet 을 주고받는다.
///
/// 연결 정책
/// - **페어링 코드(PIN)**: 사용자가 두 기기에 같은 코드를 입력하면 그 코드끼리만 연결된다.
/// - **역할 페어링**: player ↔ remote 처럼 역할이 서로 보완될 때만 연결
/// - **초대 방향**: 리모컨(remote)이 플레이어(player)를 초대 (이중 초대 방지)
/// - **자동 재연결**: 끊기면 탐색을 재시작 (연결 핸드셰이크 중에는 탐색·재초대 중단)
final class MultipeerService: NSObject, ObservableObject {

    @Published var isConnected: Bool = false
    @Published var connectedPeerNames: [String] = []
    @Published var statusDetail: String = "대기 중"
    @Published var startFailed: Bool = false
    @Published var nearbyMatchCount: Int = 0

    private var discoveredMatches = Set<MCPeerID>()
    /// 초대를 보냈거나 핸드셰이크 중인 피어 (중복 초대·탐색 재시작으로 인한 크래시 방지)
    private var pendingPeers = Set<MCPeerID>()

    var onCommand: ((CommandMessage) -> Void)?
    var onNowPlaying: ((NowPlayingMessage) -> Void)?

    private let serviceType = "ammusic-rc"
    private let myPeerID = MCPeerID(
        displayName: "\(UIDevice.current.name)#\(String(UUID().uuidString.prefix(4)))")
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private var myRole: DeviceRole = .unset
    private var myCode: String = ""
    private var pairToken: String = ""

    private var tokenContext: Data { Data(pairToken.utf8) }
    private var inviteRetryTimer: Timer?
    private var inviteRetryAttempts = 0

    /// 탐색·광고가 돌아가는 중인지
    var isActive: Bool {
        myRole != .unset && advertiser != nil && browser != nil
    }

    private var isHandshaking: Bool { !pendingPeers.isEmpty }

    override init() {
        super.init()
        makeSession()
    }

    private func makeSession() {
        session = MCSession(peer: myPeerID,
                            securityIdentity: nil,
                            encryptionPreference: .required)
        session.delegate = self
    }

    private func makeToken(code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "ptp-v1-default" }
        let digest = SHA256.hash(data: Data("ptp-v1:\(trimmed)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "ptp-v1-" + String(hex.prefix(16))
    }

    // MARK: - 시작/정지

    func start(role: DeviceRole, code: String) {
        runOnMain { self.startOnMain(role: role, code: code) }
    }

    private func startOnMain(role: DeviceRole, code: String) {
        stopOnMain()
        makeSession()
        myRole = role
        myCode = code
        pairToken = makeToken(code: code)
        pendingPeers.removeAll()
        setStatusOnMain("상대 기기 검색 중…", failed: false)

        let info = ["token": pairToken, "role": role.rawValue]
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID,
                                               discoveryInfo: info,
                                               serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()

        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
        updateConnectionStateOnMain()
        startInviteRetries()
    }

    func stop() {
        runOnMain { self.stopOnMain() }
    }

    private func stopOnMain() {
        stopInviteRetries()
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        session.disconnect()
        myRole = .unset
        discoveredMatches.removeAll()
        pendingPeers.removeAll()
        statusDetail = "대기 중"
        startFailed = false
        nearbyMatchCount = 0
        connectedPeerNames = []
        isConnected = false
    }

    func rescan() {
        runOnMain {
            guard self.myRole != .unset else { return }
            guard !self.isHandshaking else { return }
            self.discoveredMatches.removeAll()
            self.pendingPeers.removeAll()
            self.nearbyMatchCount = 0
            if self.advertiser == nil || self.browser == nil {
                self.startOnMain(role: self.myRole, code: self.myCode)
            } else {
                self.setStatusOnMain("다시 검색 중…", failed: false)
                self.restartDiscovery()
                self.startInviteRetries()
            }
        }
    }

    func wakeUp() {
        runOnMain {
            guard self.myRole != .unset else { return }
            guard self.session.connectedPeers.isEmpty else { return }
            guard !self.isHandshaking else { return }

            self.setStatusOnMain("다시 연결 중…", failed: false)
            if self.advertiser == nil || self.browser == nil {
                self.startOnMain(role: self.myRole, code: self.myCode)
                return
            }
            self.restartDiscovery()
            self.startInviteRetries()
        }
    }

    func send(_ packet: Packet) {
        runOnMain {
            guard !self.session.connectedPeers.isEmpty else { return }
            do {
                let data = try JSONEncoder().encode(packet)
                try self.session.send(data, toPeers: self.session.connectedPeers, with: .reliable)
            } catch {
                print("[MP] send 실패: \(error)")
            }
        }
    }

    // MARK: - 내부

    private func isComplementaryRole(_ otherRole: String?) -> Bool {
        switch myRole {
        case .player: return otherRole == DeviceRole.remote.rawValue
        case .remote: return otherRole == DeviceRole.player.rawValue
        case .unset:  return false
        }
    }

    private func inviteIfNeeded(_ peerID: MCPeerID) {
        guard myRole == .remote else { return }
        guard !session.connectedPeers.contains(peerID) else { return }
        guard !pendingPeers.contains(peerID) else { return }
        pendingPeers.insert(peerID)
        browser?.invitePeer(peerID, to: session, withContext: tokenContext, timeout: 20)
        // 초대 후 응답이 없으면 pending 이 영구 잠기는 것을 방지
        DispatchQueue.main.asyncAfter(deadline: .now() + 22) { [weak self] in
            guard let self else { return }
            guard !self.session.connectedPeers.contains(peerID) else { return }
            self.pendingPeers.remove(peerID)
            if self.myRole == .remote, self.session.connectedPeers.isEmpty {
                self.startInviteRetries()
            }
        }
    }

    private func scheduleRediscovery() {
        let delay: TimeInterval =
            UIApplication.shared.applicationState == .active ? 0.5 : 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.myRole != .unset else { return }
            guard self.session.connectedPeers.isEmpty else { return }
            guard !self.isHandshaking else { return }
            self.pendingPeers.removeAll()
            self.restartDiscovery()
            self.startInviteRetries()
        }
    }

    private func startInviteRetries() {
        stopInviteRetries()
        guard myRole == .remote else { return }

        inviteRetryAttempts = 0
        inviteRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.runOnMain {
                guard self.myRole != .unset else {
                    timer.invalidate()
                    return
                }
                if !self.session.connectedPeers.isEmpty {
                    self.stopInviteRetries()
                    return
                }
                if self.isHandshaking { return }

                self.inviteRetryAttempts += 1
                if self.inviteRetryAttempts > 15 {
                    timer.invalidate()
                    return
                }
                for peer in self.discoveredMatches {
                    self.inviteIfNeeded(peer)
                }
                if self.inviteRetryAttempts % 4 == 0, !self.isHandshaking {
                    self.restartDiscovery()
                }
            }
        }
        if let inviteRetryTimer {
            RunLoop.main.add(inviteRetryTimer, forMode: .common)
        }
    }

    private func stopInviteRetries() {
        inviteRetryTimer?.invalidate()
        inviteRetryTimer = nil
    }

    private func restartDiscovery() {
        guard !isHandshaking else { return }
        browser?.stopBrowsingForPeers()
        advertiser?.stopAdvertisingPeer()
        advertiser?.startAdvertisingPeer()
        browser?.startBrowsingForPeers()
    }

    private func updateConnectionStateOnMain() {
        let peers = session.connectedPeers.map {
            $0.displayName.components(separatedBy: "#").first ?? $0.displayName
        }
        connectedPeerNames = peers
        isConnected = !peers.isEmpty
    }

    private func setStatusOnMain(_ text: String, failed: Bool, matches: Int? = nil) {
        statusDetail = text
        startFailed = failed
        if let m = matches { nearbyMatchCount = m }
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() }
        else { DispatchQueue.main.async(execute: block) }
    }
}

// MARK: - MCSessionDelegate

extension MultipeerService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        runOnMain { [weak self] in
            guard let self else { return }
            switch state {
            case .connecting:
                self.pendingPeers.insert(peerID)
                self.stopInviteRetries()
                self.setStatusOnMain("연결 중…", failed: false)
            case .connected:
                self.pendingPeers.remove(peerID)
                self.discoveredMatches.remove(peerID)
                self.stopInviteRetries()
                self.updateConnectionStateOnMain()
                self.setStatusOnMain("연결됨", failed: false, matches: self.discoveredMatches.count)
            case .notConnected:
                self.pendingPeers.remove(peerID)
                self.updateConnectionStateOnMain()
                self.setStatusOnMain(
                    self.myRole == .unset ? "대기 중" : "상대 기기 검색 중…",
                    failed: false
                )
                if self.myRole == .remote, !self.isHandshaking {
                    self.startInviteRetries()
                }
                self.scheduleRediscovery()
            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let packet = try? JSONDecoder().decode(Packet.self, from: data) else { return }
        runOnMain {
            if let cmd = packet.command { self.onCommand?(cmd) }
            if let np = packet.nowPlaying { self.onNowPlaying?(np) }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Advertiser

extension MultipeerService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let token = context.flatMap { String(data: $0, encoding: .utf8) }
        let accept = (token == pairToken)
        runOnMain {
            if accept { self.pendingPeers.insert(peerID) }
            invitationHandler(accept, accept ? self.session : nil)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didNotStartAdvertisingPeer error: Error) {
        print("[MP] advertise 시작 실패: \(error)")
        runOnMain {
            self.setStatusOnMain(
                "로컬 네트워크 권한을 확인하세요 (설정 > 개인정보 보호 > 로컬 네트워크)",
                failed: true
            )
        }
    }
}

// MARK: - Browser

extension MultipeerService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser,
                 foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        runOnMain {
            let sameApp = (info?["token"] != nil)
            guard info?["token"] == self.pairToken else {
                if sameApp {
                    self.setStatusOnMain(
                        "다른 페어링 코드의 기기를 발견함 (코드를 동일하게 맞추세요)",
                        failed: false
                    )
                }
                return
            }
            guard self.isComplementaryRole(info?["role"]) else {
                self.setStatusOnMain(
                    "같은 역할의 기기를 발견함 (한쪽은 '음악 재생', 다른쪽은 '리모컨'을 고르세요)",
                    failed: false
                )
                return
            }
            self.discoveredMatches.insert(peerID)
            self.setStatusOnMain(
                "상대 기기 발견 — 연결 시도 중…",
                failed: false,
                matches: self.discoveredMatches.count
            )
            self.inviteIfNeeded(peerID)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        runOnMain {
            self.discoveredMatches.remove(peerID)
            if !self.isHandshaking {
                self.pendingPeers.remove(peerID)
            }
            self.updateConnectionStateOnMain()
            let stillConnected = !self.session.connectedPeers.isEmpty
            self.setStatusOnMain(
                stillConnected ? "연결됨" : "상대 기기 검색 중…",
                failed: false,
                matches: self.discoveredMatches.count
            )
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("[MP] browse 시작 실패: \(error)")
        runOnMain {
            self.setStatusOnMain(
                "로컬 네트워크 권한을 확인하세요 (설정 > 개인정보 보호 > 로컬 네트워크)",
                failed: true
            )
        }
    }
}
