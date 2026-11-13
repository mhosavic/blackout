import Testing
import BlackoutCore

struct ExternalDisplayControllerTests {

    /// Counts calls and answers from a script of readings
    private final class Monitor {
        var answers: [Int?]
        var calls = 0
        init(_ answers: [Int?]) { self.answers = answers }
        func read() -> Int? {
            calls += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    /// Some monitors drop a DDC read now and then (measured: about one in
    /// ten on an ASUS VG289). A single miss must not make a connected
    /// monitor count as unplugged, which would mute audio mid-work.
    @Test func aDroppedReadIsRetried() {
        let monitor = Monitor([nil, nil, 80])
        #expect(ExternalDisplayController.firstReading(attempts: 3, read: monitor.read) == 80)
        #expect(monitor.calls == 3)
    }

    @Test func stopsAtTheFirstAnswer() {
        let monitor = Monitor([80, 20])
        #expect(ExternalDisplayController.firstReading(attempts: 3, read: monitor.read) == 80)
        #expect(monitor.calls == 1)
    }

    /// A monitor that never answers is still reported as unreachable, after
    /// a bounded number of tries
    @Test func givesUpAfterTheAttempts() {
        let monitor = Monitor([nil, nil, nil, 80])
        #expect(ExternalDisplayController.firstReading(attempts: 3, read: monitor.read) == nil)
        #expect(monitor.calls == 3)
    }
}
