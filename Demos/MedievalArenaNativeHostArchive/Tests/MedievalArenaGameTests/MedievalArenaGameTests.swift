@testable import MedievalArenaGame
import Math
import Testing

@Suite("Medieval Arena")
struct MedievalArenaGameTests {
    @Test("Launch arguments select a peer")
    func parsesPeerArguments() {
        let options = ArenaLaunchOptions.parse([
            "--join", "192.168.1.20",
            "--port", "39999",
            "--peer-index", "3",
            "--bot",
            "--diagnostics", "/tmp/arena-test.log"
        ])
        #expect(options.role == .peer)
        #expect(options.host == "192.168.1.20")
        #expect(options.port == 39_999)
        #expect(options.peerIndex == 3)
        #expect(options.runsBot)
        #expect(options.diagnosticsPath == "/tmp/arena-test.log")
    }

    @Test("Sword hit respects range and facing")
    func validatesSwordArc() {
        let origin = Vector3(0, 0, 0)
        #expect(ArenaRules.isHit(attacker: origin, facing: .right, target: Vector3(50, 0, 0)))
        #expect(!ArenaRules.isHit(attacker: origin, facing: .left, target: Vector3(50, 0, 0)))
        #expect(!ArenaRules.isHit(attacker: origin, facing: .right, target: Vector3(80, 0, 0)))
        #expect(!ArenaRules.isHit(attacker: origin, facing: .up, target: Vector3(50, 0, 0)))
    }

    @Test("Player IDs are stable and distinct")
    func stablePeerIDs() {
        let host = ArenaLaunchOptions(role: .host)
        let peer = ArenaLaunchOptions(role: .peer, peerIndex: 1)
        let otherPeer = ArenaLaunchOptions(role: .peer, peerIndex: 2)
        #expect(host.peerID != peer.peerID)
        #expect(peer.peerID != otherPeer.peerID)
        #expect(peer.peerID == ArenaLaunchOptions(role: .peer, peerIndex: 1).peerID)
    }
}
