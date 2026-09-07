import Foundation

enum LabMode: Int32 {
    case air = 0, sumoDirect, sumoSC2
    var ground: Bool { self != .air }
    var host: String { self == .sumoDirect ? "192.168.2.1" : "192.168.42.88" }
    var title: String {
        switch self {
        case .air: return "AIR · SC2"
        case .sumoDirect: return "GROUND · SUMO WI-FI"
        case .sumoSC2: return "GROUND · SUMO VIA SC2"
        }
    }
}

/// A renewable input lease, not a latched throttle. The network worker checks
/// the lease independently of Qt so a stalled UI cannot keep driving.
final class GroundControl {
    private let lock = NSLock()
    private var armed = false, available = false
    private var limit = 30
    private var held = 0
    private var refreshed = -Double.infinity
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var status: (armed: Bool, ready: Bool, limit: Int) { locked { (armed, available, limit) } }
    func setAvailable(_ value: Bool) {
        locked { available = value; if !value { armed = false; held = 0 } }
    }
    func setLimit(_ value: Int) { locked { limit = min(100, max(0, value)) } }
    @discardableResult func toggleArm() -> Bool {
        locked { armed = available && !armed; held = 0; refreshed = -.infinity; return armed }
    }
    func stop() { locked { armed = false; held = 0; refreshed = -.infinity } }
    func refresh(mask: Int, now: Double = ProcessInfo.processInfo.systemUptime) {
        locked { held = armed ? mask & 15 : 0; refreshed = now }
    }
    func input(now: Double = ProcessInfo.processInfo.systemUptime) -> JumpingSumoPilotingInput {
        locked {
            guard available, armed, now - refreshed <= 0.25 else {
                // An expired lease requires explicit re-arming, even after Qt resumes.
                if armed, refreshed.isFinite { armed = false; held = 0 }
                return JumpingSumoPilotingInput(speed: 0, turn: 0)
            }
            let speed = ((held & 1 != 0 ? 1 : 0) - (held & 2 != 0 ? 1 : 0)) * limit
            let turn = ((held & 8 != 0 ? 1 : 0) - (held & 4 != 0 ? 1 : 0)) * limit
            return JumpingSumoPilotingInput(speed: Int8(speed), turn: Int8(turn))
        }
    }
}
