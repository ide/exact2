// The date and zone the session sends the runtime at boot and as the clock
// moves (LLP 1027.000.000).
import Foundation

extension ExactSession {
    /// Sends the date, zone, locale and preferences after a boot.
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
    /// Sends the machine zone's offset when it differs from the last one sent.
    /// Runs at boot and before each advance, so a DST or zone change reaches
    /// the next timer. Under the agent, `tellAgentOffset` is used instead.
    func followOffset() {
        guard launchPlace.epoch == nil else { return }
        let offset = Double(TimeZone.autoupdatingCurrent.secondsFromGMT()) / 60
        guard offset != toldOffset else { return }
        toldOffset = offset
        apply(runtime.setTime(epochAtZero: Date().timeIntervalSince1970 * 1000 - now(), utcOffset: offset))
    }
    /// Under the agent, sends the drive's date at clock zero and its zone's
    /// offset at the current virtual time. Runs at boot and after every `clock`,
    /// so crossing a DST change updates it (LLP 1069.007 D2).
    func tellAgentOffset() {
        guard let epoch = launchPlace.epoch else { return }
        let zone = TimeZone(identifier: launchPlace.timeZone) ?? TimeZone(secondsFromGMT: 0)!
        let offset = Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: (epoch + now()) / 1000))) / 60
        apply(runtime.setTime(epochAtZero: epoch, utcOffset: offset))
    }
}
