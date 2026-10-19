import Foundation
import Testing
@testable import PulseCore

@Suite struct TimestampTests {
    /// 2026-10-18T17:00:07Z
    static let expected = Date(timeIntervalSince1970: 1_792_342_807)

    @Test(arguments: [
        ("2026-10-18T17:00:07Z", 0.0),
        ("2026-10-18T17:00:07", 0),
        ("2026-10-18 17:00:07", 0),
        ("2026-10-18t17:00:07z", 0),
        ("2026-10-18T17:00:07.304Z", 0.304),
        ("2026-10-18T17:00:07,5Z", 0.5),
        ("2026-10-18T17:00:07.123456Z", 0.123456),
        ("2026-10-18T19:00:07+02:00", 0),
        ("2026-10-18T19:30:07+0230", 0),
        ("2026-10-18T19:00:07+02", 0),
        ("2026-10-18T12:30:07.250-04:30", 0.25),
    ])
    func parsesSupportedForms(_ input: String, _ fraction: Double) throws {
        let parsed = try #require(Timestamp.parse(input))
        #expect(abs(parsed.timeIntervalSince(Self.expected) - fraction) < 1e-6)
    }

    @Test(arguments: [
        "", "2026-10-18", "2026-10-18T17:00", "20261018T170007Z", "2026/10/18T17:00:07Z", "2026-10-18X17:00:07Z",
        "2026-13-01T00:00:00Z", "2026-10-32T00:00:00Z", "2026-10-18T24:00:00Z", "2026-10-18T17:60:00Z",
        "2026-10-18T17:00:07.Z", "2026-10-18T17:00:07Zjunk", "2026-10-18T17:00:07+5", "2026-10-18T17:00:07 UTC",
    ])
    func rejectsMalformedInput(_ input: String) {
        #expect(Timestamp.parse(input) == nil)
    }

    @Test func handlesCalendarEdges() {
        #expect(Timestamp.daysFromCivil(year: 1970, month: 1, day: 1) == 0)
        #expect(Timestamp.daysFromCivil(year: 2000, month: 3, day: 1) == 11_017)
        #expect(Timestamp.daysFromCivil(year: 1969, month: 12, day: 31) == -1)
        #expect(Timestamp.parse("2024-02-29T00:00:00Z") == Date(timeIntervalSince1970: 1_709_164_800))
        #expect(Timestamp.parse("1969-12-31T23:59:59Z") == Date(timeIntervalSince1970: -1))
    }

    @Test func roundTripsTheCliFormat() throws {
        let date = Date(timeIntervalSince1970: 1_792_342_807.25)
        let parsed = try #require(Timestamp.parse(iso(date)))
        #expect(abs(parsed.timeIntervalSince(date)) < 1e-6)
    }
}
