import Foundation
import MultipeerConnectivity
import UIKit
import CryptoKit

/// 같은 WiFi/근거리의 두 기기를 자동으로 찾아 연결하고, Packet 을 주고받는다.
///
/// 연결 정책
/// - **페어링 코드(PIN)**: 사용자가 두 기기에 같은 코드를 입력하면 그 코드끼리만 연결된다.
///   코드는 그대로 방송하지 않고 SHA256 해시로 변환해 토큰으로 사용(노출 최소화).
///   코드가 비어 있으면 기본 토큰으로 "같은 앱끼리" 연결(이전 동작과 호환).
/// - **역할 페어링**: player ↔ remote 처럼 역할이 서로 보완될 때만 연결(둘 다 player 등은 무시)
/// - **이중 연결 방지**: 양쪽이 동시에 초대하지 않도록 displayName 이 큰 쪽만 초대
/// - **자동 재연결**: 끊기면 잠시 후 탐색을 재시작하고, 앱이 다시 활성화될 때도 재시도
final class MultipeerService: NSObject, ObservableObject {

    @Published var isConnected: Bool = false
    @Published var connectedPeerNames: [String] = []

    /// 리모컨이 보낸 명령(플레이어 측에서 수신)
    var onCommand: ((CommandMessage) -> Void)?
    /// 플레이어가 보낸 현재 곡 정보(리모컨 측에서 수신)
    var onNowPlaying: ((NowPlayingMessage) -> Void)?

    private let serviceType = "ammusic-rc"

    // 두 기기 이름이 같아도(예: 둘 다 "iPad") 정렬·식별이 되도록 고유 접미사를 붙임
    private let myPeerID = MCPeerID(
        displayName: "\(UIDevice.current.name)#\(String(UUID().uuidString.prefix(4)))")
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    /// 이 기기의 현재 역할(탐색·초대 판단에 사용)
    private var myRole: DeviceRole = .unset
    /// 현재 페어링 코드(재연결 시 동일 코드로 재시작하기 위해 보관)
    private var myCode: String = ""
    /// 코드에서 파생된 연결 토큰(같은 값끼리만 연결)
    private var pairToken: String = ""

    private var tokenContext: Data { Data(pairToken.utf8) }

    override init() {
        super.init()
        session = MCSession(peer: myPeerID,
                            securityIdentity: nil,
                            encryptionPreference: .required)
        session.delegate = self
    }

    /// 페어링 코드 → 토큰(SHA256 앞 16자리). 코드가 비면 기본 토큰.
    private func makeToken(code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "ptp-v1-default" }
        let digest = SHA256.hash(data: Data("ptp-v1:\(trimmed)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "ptp-v1-" + String(hex.prefix(16))
    }

    // MARK: - 시작/정지
    func start(role: DeviceRole, code: String) {
        stop()  // 중복 방지
        myRole = role
        myCode = code
        pairToken = makeToken(code: code)

        // 토큰 + 역할을 광고에 실어, 상대가 검증·매칭할 수 있게 한다.
        let info = ["token": pairToken, "role": role.rawValue]
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID,
                                               discoveryInfo: info,
                                               serviceType: serviceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()

        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        session.disconnect()
        myRole = .unset
    }

    /// 앱이 다시 활성화(foreground)될 때 호출 — 끊겨 있으면 탐색을 재시작한다.
    func wakeUp() {
        guard myRole != .unset, session.connectedPeers.isEmpty else { return }
        if advertiser == nil || browser == nil {
            start(role: myRole, code: myCode)
        } else {
            restartDiscovery()
        }
    }

    func send(_ packet: Packet) {
        guard !session.connectedPeers.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(packet)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
        } catch {
            print("[MP] send 실패: \(error)")
        }
    }

    // MARK: - 내부
    /// 상대 역할이 내 역할과 보완 관계(player↔remote)인지
    private func isComplementaryRole(_ otherRole: String?) -> Bool {
        switch myRole {
        case .player: return otherRole == DeviceRole.remote.rawValue
        case .remote: return otherRole == DeviceRole.player.rawValue
        case .unset:  return false
        }
    }

    /// 이중 연결 방지 규칙(더 큰 displayName 쪽만 초대) + 미연결 상태일 때만 초대
    private func inviteIfNeeded(_ peerID: MCPeerID) {
        guard myPeerID.displayName > peerID.displayName else { return }
        guard !session.connectedPeers.contains(peerID) else { return }
        browser?.invitePeer(peerID, to: session, withContext: tokenContext, timeout: 15)
    }

    /// 끊긴 뒤 일정 시간 후 여전히 미연결이면 탐색을 재시작
    private func scheduleRediscovery() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.myRole != .unset else { return }
            guard self.session.connectedPeers.isEmpty else { return }  // 이미 재연결됐으면 패스
            self.restartDiscovery()
        }
    }

    /// advertise/browse 를 새로 시작해 fresh 한 발견 이벤트를 강제 → 재초대 트리거
    private func restartDiscovery() {
        browser?.stopBrowsingForPeers()
        advertiser?.stopAdvertisingPeer()
        advertiser?.startAdvertisingPeer()
        browser?.startBrowsingForPeers()
    }

    private func updateConnectionState() {
        // 표시용으로는 "#접미사" 를 떼어낸 친근한 이름만 사용
        let peers = session.connectedPeers.map {
            $0.displayName.components(separatedBy: "#").first ?? $0.displayName
        }
        DispatchQueue.main.async {
            self.connectedPeerNames = peers
            self.isConnected = !peers.isEmpty
        }
    }
}

// MARK: - MCSessionDelegate
extension MultipeerService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        updateConnectionState()
        if state == .notConnected {
            DispatchQueue.main.async { [weak self] in self?.scheduleRediscovery() }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let packet = try? JSONDecoder().decode(Packet.self, from: data) else { return }
        if let cmd = packet.command { onCommand?(cmd) }
        if let np = packet.nowPlaying { onNowPlaying?(np) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Advertiser (초대 수락)
extension MultipeerService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // 공유 토큰(=같은 페어링 코드)이 일치하는 초대만 수락
        let token = context.flatMap { String(data: $0, encoding: .utf8) }
        let accept = (token == pairToken)
        invitationHandler(accept, accept ? session : nil)
    }
}

// MARK: - Browser (토큰·역할 검증 후 한쪽만 초대)
extension MultipeerService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser,
                 foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String : String]?) {
        // 같은 토큰(코드) + 보완 역할일 때만 연결 후보로 인정
        guard info?["token"] == pairToken,
              isComplementaryRole(info?["role"]) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.inviteIfNeeded(peerID)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            self?.updateConnectionState()
        }
    }
}
