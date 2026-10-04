// The session's date and zone (LLP 1027.000.000): what it tells the runtime
// at boot and as the clock moves, split from Session.swift.
import Foundation

extension ExactSession {
    /// @ref LLP 1027.000.000 — the date, against the clock `now()` reads.
    func tellTime() {
        if launchPlace.epoch != nil {
            tellAgentOffset()
        } else {
            toldOffset = nil
            followOffset()
        }
        apply(runtime.setPlace(locale: launchPlace.locale, timeZone: launchPlace.timeZone, seed: launchPlace.seed))
        tellPreferences()
        tellPage()
    }
    /// The machine zone's offset now, told when it is not the one last told:
    /// at boot and before each advance, so a DST change or a new zone reaches
    /// the timer that fires after it (habits F6). Under the agent, the
    /// drive's zone moves it instead (`tellAgentOffset`).
    func followOffset() {
        guard launchPlace.epoch == nil else { return }
        let offset = Double(TimeZone.autoupdatingCurrent.secondsFromGMT()) / 60
        guard offset != toldOffset else { return }
        toldOffset = offset
        apply(runtime.setTime(epochAtZero: Date().timeIntervalSince1970 * 1000 - now(), utcOffset: offset))
    }
    /// Under the agent, the drive's date at the clock's zero and its zone's
    /// offset at the virtual instant the clock reads: told at boot and after
    /// every `clock`, so a move across a DST change re-answers it (LLP
    /// 1069.007 D2). An unchanged offset commits nothing.
    func tellAgentOffset() {
        guard let epoch = launchPlace.epoch else { return }
        let zone = TimeZone(identifier: launchPlace.timeZone) ?? TimeZone(secondsFromGMT: 0)!
        let offset = Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: (epoch + now()) / 1000))) / 60
        apply(runtime.setTime(epochAtZero: epoch, utcOffset: offset))
    }
}
