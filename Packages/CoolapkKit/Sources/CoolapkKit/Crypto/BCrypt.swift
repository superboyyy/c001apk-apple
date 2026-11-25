import Foundation

/// 精简版 bcrypt（`$2a$`），够请求签名用。
/// 按 jBCrypt 参考算法实现，结果与 Flutter 端使用的 Dart `bcrypt` 包一致。
enum BCrypt {
    private static let alphabet = Array("./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
    private static let decodeTable: [Int8] = {
        var table = [Int8](repeating: -1, count: 128)
        for (index, char) in alphabet.enumerated() { table[Int(char)] = Int8(index) }
        return table
    }()
    /// 即 "OrpheanBeholderScryDoubt"。
    private static let magic: [UInt32] = [
        0x4f72_7068, 0x6561_6e42, 0x6568_6f6c, 0x6465_7253, 0x6372_7944, 0x6f75_6274,
    ]

    enum Failure: Error { case invalidSalt }

    /// `salt` 的格式为 `$2a$NN$` 加 22 个 bcrypt-base64 字符。
    static func hash(password: String, salt: String) throws -> String {
        let chars = Array(salt.utf8)
        guard chars.count >= 29, chars[0] == UInt8(ascii: "$"), chars[1] == UInt8(ascii: "2"),
              chars[3] == UInt8(ascii: "$"), chars[6] == UInt8(ascii: "$"),
              let logRounds = Int(String(decoding: chars[4..<6], as: UTF8.self)),
              (4...31).contains(logRounds)
        else { throw Failure.invalidSalt }
        let minor = chars[2]
        let saltBytes = try decode(Array(chars[7..<29]), maxLength: 16)
        guard saltBytes.count == 16 else { throw Failure.invalidSalt }

        var passwordBytes = Array(password.utf8)
        if minor >= UInt8(ascii: "a") { passwordBytes.append(0) }

        let hashed = cryptRaw(password: passwordBytes, salt: saltBytes, logRounds: logRounds)

        var out = "$2" + String(UnicodeScalar(minor)) + "$"
        out += logRounds < 10 ? "0\(logRounds)" : "\(logRounds)"
        out += "$"
        out += encode(saltBytes, length: 16)
        out += encode(hashed, length: magic.count * 4 - 1)
        return out
    }

    // MARK: - Base64（bcrypt 变体）

    private static func encode(_ data: [UInt8], length: Int) -> String {
        var out = [UInt8]()
        var offset = 0
        while offset < length {
            var c1 = Int(data[offset]); offset += 1
            out.append(alphabet[(c1 >> 2) & 0x3f])
            c1 = (c1 & 0x03) << 4
            if offset >= length { out.append(alphabet[c1 & 0x3f]); break }
            var c2 = Int(data[offset]); offset += 1
            c1 |= (c2 >> 4) & 0x0f
            out.append(alphabet[c1 & 0x3f])
            c1 = (c2 & 0x0f) << 2
            if offset >= length { out.append(alphabet[c1 & 0x3f]); break }
            c2 = Int(data[offset]); offset += 1
            c1 |= (c2 >> 6) & 0x03
            out.append(alphabet[c1 & 0x3f])
            out.append(alphabet[c2 & 0x3f])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func char64(_ char: UInt8) throws -> Int {
        guard char < 128, decodeTable[Int(char)] >= 0 else { throw Failure.invalidSalt }
        return Int(decodeTable[Int(char)])
    }

    private static func decode(_ chars: [UInt8], maxLength: Int) throws -> [UInt8] {
        var out = [UInt8]()
        var offset = 0
        while offset < chars.count - 1, out.count < maxLength {
            let c1 = try char64(chars[offset]); offset += 1
            let c2 = try char64(chars[offset]); offset += 1
            out.append(UInt8(truncatingIfNeeded: (c1 << 2) | ((c2 & 0x30) >> 4)))
            if out.count >= maxLength || offset >= chars.count { break }
            let c3 = try char64(chars[offset]); offset += 1
            out.append(UInt8(truncatingIfNeeded: ((c2 & 0x0f) << 4) | ((c3 & 0x3c) >> 2)))
            if out.count >= maxLength || offset >= chars.count { break }
            let c4 = try char64(chars[offset]); offset += 1
            out.append(UInt8(truncatingIfNeeded: ((c3 & 0x03) << 6) | c4))
        }
        return out
    }

    // MARK: - Eksblowfish

    private struct State {
        var p = BlowfishTables.p
        var s = BlowfishTables.s

        @inline(__always)
        mutating func encipher(_ l: inout UInt32, _ r: inout UInt32) {
            var left = l ^ p[0]
            var right = r
            var i = 0
            while i <= 14 {
                var n = s[Int(left >> 24)]
                n = n &+ s[0x100 | Int((left >> 16) & 0xff)]
                n ^= s[0x200 | Int((left >> 8) & 0xff)]
                n = n &+ s[0x300 | Int(left & 0xff)]
                i += 1
                right ^= n ^ p[i]

                n = s[Int(right >> 24)]
                n = n &+ s[0x100 | Int((right >> 16) & 0xff)]
                n ^= s[0x200 | Int((right >> 8) & 0xff)]
                n = n &+ s[0x300 | Int(right & 0xff)]
                i += 1
                left ^= n ^ p[i]
            }
            l = right ^ p[17]
            r = left
        }

        static func word(_ data: [UInt8], _ offset: inout Int) -> UInt32 {
            var word: UInt32 = 0
            for _ in 0..<4 {
                word = (word << 8) | UInt32(data[offset])
                offset = (offset + 1) % data.count
            }
            return word
        }

        mutating func key(_ key: [UInt8]) {
            var offset = 0
            for i in 0..<18 { p[i] ^= State.word(key, &offset) }
            var l: UInt32 = 0, r: UInt32 = 0
            for i in stride(from: 0, to: 18, by: 2) {
                encipher(&l, &r)
                p[i] = l; p[i + 1] = r
            }
            for i in stride(from: 0, to: 1024, by: 2) {
                encipher(&l, &r)
                s[i] = l; s[i + 1] = r
            }
        }

        mutating func expensiveKey(data: [UInt8], key: [UInt8]) {
            var keyOffset = 0, dataOffset = 0
            for i in 0..<18 { p[i] ^= State.word(key, &keyOffset) }
            var l: UInt32 = 0, r: UInt32 = 0
            for i in stride(from: 0, to: 18, by: 2) {
                l ^= State.word(data, &dataOffset)
                r ^= State.word(data, &dataOffset)
                encipher(&l, &r)
                p[i] = l; p[i + 1] = r
            }
            for i in stride(from: 0, to: 1024, by: 2) {
                l ^= State.word(data, &dataOffset)
                r ^= State.word(data, &dataOffset)
                encipher(&l, &r)
                s[i] = l; s[i + 1] = r
            }
        }
    }

    private static func cryptRaw(password: [UInt8], salt: [UInt8], logRounds: Int) -> [UInt8] {
        var state = State()
        state.expensiveKey(data: salt, key: password)
        for _ in 0..<(1 << logRounds) {
            state.key(password)
            state.key(salt)
        }
        var data = magic
        for _ in 0..<64 {
            for j in 0..<(data.count >> 1) {
                var l = data[j << 1], r = data[(j << 1) + 1]
                state.encipher(&l, &r)
                data[j << 1] = l; data[(j << 1) + 1] = r
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(data.count * 4)
        for word in data {
            out.append(UInt8(truncatingIfNeeded: word >> 24))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word))
        }
        return out
    }
}
