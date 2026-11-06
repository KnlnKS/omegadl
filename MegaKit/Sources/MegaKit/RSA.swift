import BigInt
import Foundation

struct RSAPrivateKey: Sendable {
    let p: BigUInt
    let q: BigUInt
    let d: BigUInt
    let u: BigUInt

    init?(privkBlob: Data) {
        guard let components = MPI.decode(privkBlob, count: 4) else { return nil }
        (p, q, d, u) = (components[0], components[1], components[2], components[3])
        guard p > 1, q > 1 else { return nil }
    }

    func decrypt(_ ciphertext: BigUInt) -> Data {
        let xp = (ciphertext % p).power(d % (p - 1), modulus: p)
        let xq = (ciphertext % q).power(d % (q - 1), modulus: q)

        let m: BigUInt
        if xp > xq {
            let remainder = ((xp - xq) * u) % q
            m = remainder == 0 ? 0 : q - remainder
        } else {
            m = ((xq - xp) * u) % q
        }
        return (m * p + xp).serialize()
    }
}

enum MPI {
    static func decode(_ data: Data, count: Int) -> [BigUInt]? {
        var offset = data.startIndex
        var components = [BigUInt]()

        for _ in 0..<count {
            guard data.index(offset, offsetBy: 2, limitedBy: data.endIndex) != nil else { return nil }
            let bits = Int(data[offset]) << 8 | Int(data[offset + 1])
            let byteCount = (bits + 7) / 8
            let start = offset + 2
            guard start + byteCount <= data.endIndex else { return nil }
            components.append(BigUInt(Data(data[start..<(start + byteCount)])))
            offset = start + byteCount
        }
        return components
    }

    static func value(_ data: Data) -> BigUInt? {
        guard data.count > 2 else { return nil }
        return BigUInt(Data(data.dropFirst(2)))
    }
}
