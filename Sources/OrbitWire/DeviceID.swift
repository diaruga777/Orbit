import Foundation
import CryptoKit

/// A Syncthing device ID: the SHA-256 of the peer's DER certificate.
///
/// The text form is base32 without padding, split into four 13-character
/// groups that each gain a luhn32 check character, then dashed every seven
/// characters (`claudedocs/vault-bep-reference.md` §D). `DeviceIDTests` pins
/// the text form against IDs a real Syncthing printed.
public struct DeviceID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let bytes: Data

    public enum ParseError: Error, Equatable {
        case wrongLength(Int)
        case badCheckCharacter(group: Int)
        case invalidCharacter(Character)
    }

    public init(bytes: Data) throws {
        guard bytes.count == 32 else { throw ParseError.wrongLength(bytes.count) }
        self.bytes = bytes
    }

    /// Hashes a DER certificate.
    public init(certificateDER: Data) {
        bytes = Data(SHA256.hash(data: certificateDER))
    }

    /// Accepts the 56-character checked form, the 52-character unchecked form,
    /// dashes, spaces, lowercase, and the `0→O`, `1→I`, `8→B` typo repairs
    /// Syncthing itself performs.
    public init(string: String) throws {
        var cleaned = ""
        for scalar in string.uppercased().unicodeScalars {
            switch scalar {
            case "-", " ", "=": continue
            case "0": cleaned.append("O")
            case "1": cleaned.append("I")
            case "8": cleaned.append("B")
            default: cleaned.append(Character(scalar))
            }
        }
        var unchecked = cleaned
        if cleaned.count == 56 {
            unchecked = ""
            let chars = Array(cleaned)
            for group in 0..<4 {
                let slice = chars[(group * 14)..<(group * 14 + 14)]
                let body = String(slice.prefix(13))
                guard let check = try Luhn32.check(body), check == slice[slice.startIndex + 13] else {
                    throw ParseError.badCheckCharacter(group: group)
                }
                unchecked += body
            }
        } else if cleaned.count != 52 {
            throw ParseError.wrongLength(cleaned.count)
        }
        guard let decoded = Base32.decode(unchecked + "====") else {
            throw ParseError.invalidCharacter(unchecked.first(where: { !Base32.alphabet.contains($0) }) ?? "?")
        }
        try self.init(bytes: decoded)
    }

    /// The checked, dashed 63-character form.
    public var description: String {
        let raw = Base32.encode(bytes)  // 56 chars with ==== padding
        let unchecked = String(raw.prefix(52))
        let chars = Array(unchecked)
        var checked = ""
        for group in 0..<4 {
            let body = String(chars[(group * 13)..<(group * 13 + 13)])
            checked += body
            checked.append(try! Luhn32.check(body)!)
        }
        var dashed = ""
        for (index, character) in checked.enumerated() {
            if index > 0 && index % 7 == 0 { dashed.append("-") }
            dashed.append(character)
        }
        return dashed
    }

    /// The first 8 bytes as a big-endian integer: the `Counter.id` of a
    /// version vector.
    public var shortID: UInt64 {
        bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// The seven-character short form Syncthing shows in conflict file names.
    public var shortString: String {
        String(Base32.encode(bytes.prefix(8)).prefix(7))
    }

    public static func == (lhs: DeviceID, rhs: DeviceID) -> Bool { lhs.bytes == rhs.bytes }
    public func hash(into hasher: inout Hasher) { hasher.combine(bytes) }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        try self.init(string: string)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Syncthing's check character: not standard Luhn. The factor alternates
/// 1, 2, 1, 2 starting at 1, and each addend is folded as `a / 32 + a % 32`.
enum Luhn32 {
    static func check(_ input: String) throws -> Character? {
        var factor = 1
        var sum = 0
        let n = 32
        for character in input {
            guard let codepoint = Base32.alphabet.firstIndex(of: character) else {
                throw DeviceID.ParseError.invalidCharacter(character)
            }
            let value = Base32.alphabet.distance(from: Base32.alphabet.startIndex, to: codepoint)
            var addend = factor * value
            factor = factor == 2 ? 1 : 2
            addend = addend / n + addend % n
            sum += addend
        }
        let remainder = sum % n
        let check = (n - remainder) % n
        return Base32.alphabet[Base32.alphabet.index(Base32.alphabet.startIndex, offsetBy: check)]
    }
}

/// RFC 4648 base32 with `=` padding.
public enum Base32 {
    public static let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    private static let table: [Character] = Array(alphabet)
    private static let reverse: [Character: UInt8] = {
        var map: [Character: UInt8] = [:]
        for (index, character) in alphabet.enumerated() { map[character] = UInt8(index) }
        return map
    }()

    public static func encode(_ data: Data) -> String {
        var output = ""
        var buffer: UInt64 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(table[Int((buffer >> UInt64(bits)) & 0x1F)])
            }
        }
        if bits > 0 {
            output.append(table[Int((buffer << UInt64(5 - bits)) & 0x1F)])
        }
        while output.count % 8 != 0 { output.append("=") }
        return output
    }

    public static func decode(_ string: String) -> Data? {
        var output = Data()
        var buffer: UInt64 = 0
        var bits = 0
        for character in string {
            if character == "=" { break }
            guard let value = reverse[character] else { return nil }
            buffer = (buffer << 5) | UInt64(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> UInt64(bits)) & 0xFF))
            }
        }
        return output
    }
}
