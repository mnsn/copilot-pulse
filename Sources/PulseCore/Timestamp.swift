import Foundation

/// Allocation-free ISO-8601 parser for timestamps like `2026-10-18T17:00:07.304Z`.
/// Used for every event line, so it avoids (non-Sendable, slow) formatter objects.
public enum Timestamp {
    public static func parse(_ string: String) -> Date? {
        var copy = string
        return copy.withUTF8 { parse(UnsafeRawBufferPointer($0)) }
    }

    /// Accepts `YYYY-MM-DD(T| )HH:MM:SS[.fraction][Z|±HH[:MM]]`.
    public static func parse(_ bytes: UnsafeRawBufferPointer) -> Date? {
        let count = bytes.count
        guard count >= 19 else { return nil }

        func digit(_ index: Int) -> Int? {
            let byte = bytes[index]
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            return Int(byte &- 0x30)
        }
        func number(_ start: Int, _ length: Int) -> Int? {
            var value = 0
            for index in start..<(start + length) {
                guard let d = digit(index) else { return nil }
                value = value * 10 + d
            }
            return value
        }

        guard let year = number(0, 4), bytes[4] == 0x2D,
              let month = number(5, 2), bytes[7] == 0x2D,
              let day = number(8, 2),
              bytes[10] == 0x54 || bytes[10] == 0x74 || bytes[10] == 0x20,
              let hour = number(11, 2), bytes[13] == 0x3A,
              let minute = number(14, 2), bytes[16] == 0x3A,
              let second = number(17, 2)
        else { return nil }
        guard (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second <= 60
        else { return nil }

        var index = 19
        var fraction = 0.0
        if index < count, bytes[index] == 0x2E || bytes[index] == 0x2C {
            index += 1
            var scale = 0.1
            var sawDigit = false
            while index < count, let d = digit(index) {
                fraction += Double(d) * scale
                scale /= 10
                index += 1
                sawDigit = true
            }
            guard sawDigit else { return nil }
        }

        var offsetSeconds = 0
        if index < count {
            switch bytes[index] {
            case 0x5A, 0x7A: // Z
                index += 1
            case 0x2B, 0x2D: // + or -
                let sign = bytes[index] == 0x2D ? -1 : 1
                index += 1
                guard index + 2 <= count, let offsetHours = number(index, 2) else { return nil }
                index += 2
                if index < count, bytes[index] == 0x3A { index += 1 }
                var offsetMinutes = 0
                if index + 2 <= count, let minutes = number(index, 2) {
                    offsetMinutes = minutes
                    index += 2
                }
                offsetSeconds = sign * (offsetHours * 3_600 + offsetMinutes * 60)
            default:
                return nil
            }
        }
        guard index == count else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let whole = days * 86_400 + hour * 3_600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(whole) + fraction)
    }

    /// Howard Hinnant's days-from-civil algorithm (proleptic Gregorian calendar).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
