import Foundation

/// BLAKE2b (RFC 7693), unkeyed, any output length from 1 to 64 bytes. Only Argon2 uses it.
struct BLAKE2b {
    private static let iv: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ]
    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    private var h: [UInt64]
    private var buffer: [UInt8] = []
    private var counter: UInt64 = 0
    private let outLength: Int

    init(outputLength: Int) {
        precondition(outputLength >= 1 && outputLength <= 64)
        outLength = outputLength
        h = Self.iv
        h[0] ^= 0x01010000 ^ UInt64(outputLength)
    }

    mutating func update(_ bytes: [UInt8]) {
        for byte in bytes {
            if buffer.count == 128 {
                counter &+= 128
                compress(buffer, last: false)
                buffer.removeAll(keepingCapacity: true)
            }
            buffer.append(byte)
        }
    }

    mutating func update(le32 value: UInt32) {
        update([UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)])
    }

    mutating func finalize() -> [UInt8] {
        counter &+= UInt64(buffer.count)
        buffer += [UInt8](repeating: 0, count: 128 - buffer.count)
        compress(buffer, last: true)
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for word in h { for i in 0..<8 { out.append(UInt8((word >> (8 * UInt64(i))) & 0xff)) } }
        return Array(out.prefix(outLength))
    }

    static func hash(_ bytes: [UInt8], outputLength: Int = 64) -> [UInt8] {
        var state = BLAKE2b(outputLength: outputLength)
        state.update(bytes)
        return state.finalize()
    }

    private mutating func compress(_ block: [UInt8], last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            var word: UInt64 = 0
            for j in 0..<8 { word |= UInt64(block[i * 8 + j]) << (8 * UInt64(j)) }
            m[i] = word
        }
        var v = h + Self.iv
        v[12] ^= counter
        if last { v[14] = ~v[14] }
        func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x; v[d] = (v[d] ^ v[a]).rotatedRight(32)
            v[c] = v[c] &+ v[d]; v[b] = (v[b] ^ v[c]).rotatedRight(24)
            v[a] = v[a] &+ v[b] &+ y; v[d] = (v[d] ^ v[a]).rotatedRight(16)
            v[c] = v[c] &+ v[d]; v[b] = (v[b] ^ v[c]).rotatedRight(63)
        }
        for round in 0..<12 {
            let s = Self.sigma[round % 10]
            g(0, 4, 8, 12, m[s[0]], m[s[1]]); g(1, 5, 9, 13, m[s[2]], m[s[3]])
            g(2, 6, 10, 14, m[s[4]], m[s[5]]); g(3, 7, 11, 15, m[s[6]], m[s[7]])
            g(0, 5, 10, 15, m[s[8]], m[s[9]]); g(1, 6, 11, 12, m[s[10]], m[s[11]])
            g(2, 7, 8, 13, m[s[12]], m[s[13]]); g(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0..<8 { h[i] ^= v[i] ^ v[i + 8] }
    }
}

extension UInt64 {
    @inline(__always) func rotatedRight(_ n: UInt64) -> UInt64 { (self >> n) | (self << (64 - n)) }
}

/// Argon2id (RFC 9106, version 0x13). The Flutter app derives its WebDAV sync key with it
/// (19 MiB, 2 passes, 1 lane), so the native app needs it to open the same sync folder.
public enum Argon2id {
    private static let blockWords = 128
    private static let syncPoints = 4

    public static func hash(password: [UInt8], salt: [UInt8], secret: [UInt8] = [], associatedData: [UInt8] = [],
                            iterations: Int, memoryKiB: Int, parallelism: Int, length: Int = 32) -> [UInt8] {
        precondition(parallelism >= 1 && iterations >= 1 && memoryKiB >= 8 * parallelism && length >= 4)
        var h0 = BLAKE2b(outputLength: 64)
        for value in [parallelism, length, memoryKiB, iterations, 0x13, 2] { h0.update(le32: UInt32(value)) }
        for field in [password, salt, secret, associatedData] {
            h0.update(le32: UInt32(field.count))
            h0.update(field)
        }
        let seed = h0.finalize()

        let segmentLength = memoryKiB / (syncPoints * parallelism)
        let laneLength = segmentLength * syncPoints
        let blockCount = laneLength * parallelism
        var memory = [UInt64](repeating: 0, count: blockCount * blockWords)

        for lane in 0..<parallelism {
            for column in 0..<2 {
                let bytes = variableHash(seed + le32(UInt32(column)) + le32(UInt32(lane)), length: 1024)
                let base = (lane * laneLength + column) * blockWords
                for i in 0..<blockWords { memory[base + i] = readLE64(bytes, i * 8) }
            }
        }

        memory.withUnsafeMutableBufferPointer { mem in
            var address = [UInt64](repeating: 0, count: blockWords)
            var input = [UInt64](repeating: 0, count: blockWords)
            let zero = [UInt64](repeating: 0, count: blockWords)
            var scratchR = [UInt64](repeating: 0, count: blockWords)
            var scratchT = [UInt64](repeating: 0, count: blockWords)

            func nextAddresses() {
                input[6] &+= 1
                var tmp = [UInt64](repeating: 0, count: blockWords)
                zero.withUnsafeBufferPointer { z in input.withUnsafeBufferPointer { inp in tmp.withUnsafeMutableBufferPointer { out in
                    fill(prev: z.baseAddress!, ref: inp.baseAddress!, next: out.baseAddress!, withXor: false,
                         r: &scratchR, t: &scratchT)
                } } }
                zero.withUnsafeBufferPointer { z in tmp.withUnsafeBufferPointer { inp in address.withUnsafeMutableBufferPointer { out in
                    fill(prev: z.baseAddress!, ref: inp.baseAddress!, next: out.baseAddress!, withXor: false,
                         r: &scratchR, t: &scratchT)
                } } }
            }

            for pass in 0..<iterations {
                for slice in 0..<syncPoints {
                    for lane in 0..<parallelism {
                        let independent = pass == 0 && slice < syncPoints / 2
                        if independent {
                            for i in 0..<blockWords { input[i] = 0 }
                            input[0] = UInt64(pass); input[1] = UInt64(lane); input[2] = UInt64(slice)
                            input[3] = UInt64(blockCount); input[4] = UInt64(iterations); input[5] = 2
                        }
                        let start = (pass == 0 && slice == 0) ? 2 : 0
                        if independent && start != 0 { nextAddresses() }
                        var current = lane * laneLength + slice * segmentLength + start
                        var previous = current % laneLength == 0 ? current + laneLength - 1 : current - 1
                        for index in start..<segmentLength {
                            if current % laneLength == 1 { previous = current - 1 }
                            let random: UInt64
                            if independent {
                                if index % blockWords == 0 { nextAddresses() }
                                random = address[index % blockWords]
                            } else {
                                random = mem[previous * blockWords]
                            }
                            var refLane = Int((random >> 32) % UInt64(parallelism))
                            if pass == 0 && slice == 0 { refLane = lane }
                            let refIndex = referenceIndex(pass: pass, slice: slice, index: index, sameLane: refLane == lane,
                                                          random: random & 0xffff_ffff,
                                                          segmentLength: segmentLength, laneLength: laneLength)
                            let base = mem.baseAddress!
                            fill(prev: base + previous * blockWords, ref: base + (refLane * laneLength + refIndex) * blockWords,
                                 next: base + current * blockWords, withXor: pass != 0, r: &scratchR, t: &scratchT)
                            current += 1
                            previous += 1
                        }
                    }
                }
            }
        }

        var final = [UInt64](repeating: 0, count: blockWords)
        for lane in 0..<parallelism {
            let base = (lane * laneLength + laneLength - 1) * blockWords
            for i in 0..<blockWords { final[i] ^= memory[base + i] }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(1024)
        for word in final { for j in 0..<8 { bytes.append(UInt8((word >> (8 * UInt64(j))) & 0xff)) } }
        return variableHash(bytes, length: length)
    }

    private static func referenceIndex(pass: Int, slice: Int, index: Int, sameLane: Bool, random: UInt64,
                                       segmentLength: Int, laneLength: Int) -> Int {
        let area: Int
        if pass == 0 {
            if slice == 0 { area = index - 1 }
            else if sameLane { area = slice * segmentLength + index - 1 }
            else { area = slice * segmentLength + (index == 0 ? -1 : 0) }
        } else {
            area = sameLane ? laneLength - segmentLength + index - 1
                            : laneLength - segmentLength + (index == 0 ? -1 : 0)
        }
        var relative = (random &* random) >> 32
        relative = UInt64(area) - 1 - ((UInt64(area) &* relative) >> 32)
        let start = pass != 0 && slice != syncPoints - 1 ? (slice + 1) * segmentLength : 0
        return (start + Int(relative)) % laneLength
    }

    /// The compression function G: next = P(prev ^ ref) ^ (prev ^ ref) [^ next].
    private static func fill(prev: UnsafePointer<UInt64>, ref: UnsafePointer<UInt64>, next: UnsafeMutablePointer<UInt64>,
                             withXor: Bool, r: inout [UInt64], t: inout [UInt64]) {
        for i in 0..<blockWords {
            r[i] = prev[i] ^ ref[i]
            t[i] = withXor ? r[i] ^ next[i] : r[i]
        }
        r.withUnsafeMutableBufferPointer { v in
            let p = v.baseAddress!
            for i in 0..<8 {
                let b = 16 * i
                permute(p, b, b + 1, b + 2, b + 3, b + 4, b + 5, b + 6, b + 7,
                      b + 8, b + 9, b + 10, b + 11, b + 12, b + 13, b + 14, b + 15)
            }
            for i in 0..<8 {
                let b = 2 * i
                permute(p, b, b + 1, b + 16, b + 17, b + 32, b + 33, b + 48, b + 49,
                      b + 64, b + 65, b + 80, b + 81, b + 96, b + 97, b + 112, b + 113)
            }
        }
        for i in 0..<blockWords { next[i] = t[i] ^ r[i] }
    }

    @inline(__always)
    private static func permute(_ v: UnsafeMutablePointer<UInt64>, _ i0: Int, _ i1: Int, _ i2: Int, _ i3: Int,
                              _ i4: Int, _ i5: Int, _ i6: Int, _ i7: Int, _ i8: Int, _ i9: Int, _ i10: Int,
                              _ i11: Int, _ i12: Int, _ i13: Int, _ i14: Int, _ i15: Int) {
        gb(v, i0, i4, i8, i12); gb(v, i1, i5, i9, i13); gb(v, i2, i6, i10, i14); gb(v, i3, i7, i11, i15)
        gb(v, i0, i5, i10, i15); gb(v, i1, i6, i11, i12); gb(v, i2, i7, i8, i13); gb(v, i3, i4, i9, i14)
    }

    @inline(__always)
    private static func gb(_ v: UnsafeMutablePointer<UInt64>, _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        func mul(_ x: UInt64, _ y: UInt64) -> UInt64 { 2 &* (x & 0xffff_ffff) &* (y & 0xffff_ffff) }
        v[a] = v[a] &+ v[b] &+ mul(v[a], v[b]); v[d] = (v[d] ^ v[a]).rotatedRight(32)
        v[c] = v[c] &+ v[d] &+ mul(v[c], v[d]); v[b] = (v[b] ^ v[c]).rotatedRight(24)
        v[a] = v[a] &+ v[b] &+ mul(v[a], v[b]); v[d] = (v[d] ^ v[a]).rotatedRight(16)
        v[c] = v[c] &+ v[d] &+ mul(v[c], v[d]); v[b] = (v[b] ^ v[c]).rotatedRight(63)
    }

    /// H' from RFC 9106 section 3.3.
    static func variableHash(_ input: [UInt8], length: Int) -> [UInt8] {
        if length <= 64 {
            var state = BLAKE2b(outputLength: length)
            state.update(le32: UInt32(length))
            state.update(input)
            return state.finalize()
        }
        var state = BLAKE2b(outputLength: 64)
        state.update(le32: UInt32(length))
        state.update(input)
        var v = state.finalize()
        var out = Array(v.prefix(32))
        let r = (length + 31) / 32 - 2
        if r >= 2 {
            for _ in 2...r {
                v = BLAKE2b.hash(v)
                out += v.prefix(32)
            }
        }
        out += BLAKE2b.hash(v, outputLength: length - 32 * r)
        return out
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)]
    }

    private static func readLE64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var word: UInt64 = 0
        for j in 0..<8 { word |= UInt64(bytes[offset + j]) << (8 * UInt64(j)) }
        return word
    }
}
