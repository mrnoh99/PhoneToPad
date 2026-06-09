import Foundation
import MultipeerConnectivity
import UIKit

/// 같은 WiFi 의 두 기기를 자동으로 찾아 연결하고, Packet 을 주고받는다.
/// 양쪽 모두 advertise + browse 하되, displayName 비교로 한쪽만 초대를 보내
/// 중복 연결을 피한다.
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

    override init() {
        super.init()
        session = MCSession(peer: myPeerID,
                            securityIdentity: nil,
                            encryptionPreference: .required)
        session.delegate = self
    }

    func start() {
        stop()  // 중복 방지
        advertiser = MCNearbyServiceAdvertiser(peer: myPeerID,
                                               discoveryInfo: nil,
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
        // 동일 소유자 기기이므로 무조건 수락
        invitationHandler(true, session)
    }
}

// MARK: - Browser (한쪽만 초대)
extension MultipeerService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser,
                 foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String : String]?) {
        // displayName 이 더 큰 쪽만 초대를 보내 양쪽 동시 초대 충돌을 방지
        if myPeerID.displayName > peerID.displayName {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        updateConnectionState()
    }
}
