/// One `profiles` refresh at a time. A plain trigger during a run is dropped (the run in
/// flight answers it); a `fresh` trigger during a run is remembered and started when that
/// run ends, because it needs a read that began after its caller's verb exited.
public struct RefreshGate: Sendable {
    private var running = false
    private var pendingFresh = false

    public init() {}

    /// True when the caller should start a run now.
    public mutating func request(fresh: Bool) -> Bool {
        if running {
            if fresh { pendingFresh = true }
            return false
        }
        running = true
        return true
    }

    /// Ends the current run. True when a fresh request arrived meanwhile: the caller
    /// starts that fresh run, and the gate stays held for it.
    public mutating func finish() -> Bool {
        if pendingFresh {
            pendingFresh = false
            return true
        }
        running = false
        return false
    }
}
