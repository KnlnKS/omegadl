import CommonCrypto
import Foundation

public enum AES128 {
    public static let blockSize = kCCBlockSizeAES128
    public static let keySize = kCCKeySizeAES128

    public static func ecbEncrypt(_ data: Data, key: Data) -> Data {
        crypt(data, key: key, operation: kCCEncrypt, options: kCCOptionECBMode, iv: nil)
    }

    public static func ecbDecrypt(_ data: Data, key: Data) -> Data {
        crypt(data, key: key, operation: kCCDecrypt, options: kCCOptionECBMode, iv: nil)
    }

    public static func cbcEncryptZeroIV(_ data: Data, key: Data) -> Data {
        crypt(data, key: key, operation: kCCEncrypt, options: 0, iv: Data(count: blockSize))
    }

    public static func cbcDecryptZeroIV(_ data: Data, key: Data) -> Data {
        crypt(data, key: key, operation: kCCDecrypt, options: 0, iv: Data(count: blockSize))
    }

    private static func crypt(_ data: Data, key: Data, operation: Int, options: Int, iv: Data?) -> Data {
        precondition(key.count == keySize, "MEGA uses AES-128 exclusively")
        precondition(data.count % blockSize == 0, "unpadded modes require whole blocks")
        guard !data.isEmpty else { return Data() }

        var output = Data(count: data.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    withOptionalBytes(iv) { ivBytes in
                        CCCrypt(
                            CCOperation(operation), CCAlgorithm(kCCAlgorithmAES), CCOptions(options),
                            keyBytes.baseAddress, keyBytes.count,
                            ivBytes,
                            input.baseAddress, input.count,
                            out.baseAddress, out.count, &moved
                        )
                    }
                }
            }
        }
        precondition(status == kCCSuccess && moved == data.count)
        return output
    }
}

public final class CTRCryptor {
    private var cryptor: CCCryptorRef?

    public init(key: Data, nonce: Data, blockOffset: UInt64 = 0) {
        precondition(key.count == AES128.keySize)
        precondition(nonce.count == 8)

        var counter = nonce
        withUnsafeBytes(of: blockOffset.bigEndian) { counter.append(contentsOf: $0) }

        let status = counter.withUnsafeBytes { iv in
            key.withUnsafeBytes { keyBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), iv.baseAddress, keyBytes.baseAddress, keyBytes.count,
                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor
                )
            }
        }
        precondition(status == kCCSuccess)
    }

    deinit {
        if let cryptor { CCCryptorRelease(cryptor) }
    }

    public func process(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var output = Data(count: data.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                CCCryptorUpdate(cryptor, input.baseAddress, input.count, out.baseAddress, out.count, &moved)
            }
        }
        precondition(status == kCCSuccess && moved == data.count)
        return output
    }
}

public enum PBKDF2 {
    public static func sha512(password: Data, salt: Data, iterations: Int, length: Int) -> Data {
        var output = Data(count: length)
        let status = output.withUnsafeMutableBytes { out in
            password.withUnsafeBytes { pw in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw.baseAddress?.assumingMemoryBound(to: CChar.self), pw.count,
                        s.baseAddress?.assumingMemoryBound(to: UInt8.self), s.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), UInt32(iterations),
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), length
                    )
                }
            }
        }
        precondition(status == kCCSuccess)
        return output
    }
}

func withOptionalBytes<R>(_ data: Data?, _ body: (UnsafeRawPointer?) -> R) -> R {
    guard let data else { return body(nil) }
    return data.withUnsafeBytes { body($0.baseAddress) }
}

extension Data {
    func xor(_ other: Data) -> Data {
        precondition(count == other.count)
        return Data(zip(self, other).map(^))
    }
}
