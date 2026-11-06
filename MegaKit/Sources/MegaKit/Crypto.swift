import CommonCrypto
import Foundation

/// One AES block held inline. MEGA keys, IVs and chunk MACs all have this shape.
public typealias AESBlock = SIMD16<UInt8>

extension AESBlock {
    static func random() -> AESBlock {
        var generator = SystemRandomNumberGenerator()
        return unsafeBitCast((generator.next() as UInt64, generator.next() as UInt64), to: AESBlock.self)
    }

    init?(_ bytes: UnsafeRawBufferPointer) {
        guard bytes.count == 16 else { return nil }
        self = bytes.loadUnaligned(as: AESBlock.self)
    }

    /// Collapses a CBC-MAC into MEGA's 8-byte form by xoring adjacent 32-bit words.
    var condensed: SIMD8<UInt8> {
        SIMD8(lowHalf: lowHalf.lowHalf ^ lowHalf.highHalf, highHalf: highHalf.lowHalf ^ highHalf.highHalf)
    }
}

/// An AES-128 context whose key schedule is built once and reused for every call.
struct Cryptor: ~Copyable {
    private let ref: CCCryptorRef

    init(_ operation: Int, mode: Int, key: AESBlock, iv: AESBlock = .zero) {
        var key = key
        var iv = iv
        var ref: CCCryptorRef?
        let status = CCCryptorCreateWithMode(
            CCOperation(operation), CCMode(mode), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
            &iv, &key, kCCKeySizeAES128, nil, 0, 0,
            CCModeOptions(mode == kCCModeCTR ? kCCModeOptionCTR_BE : 0), &ref
        )
        precondition(status == kCCSuccess, "AES context creation failed")
        self.ref = ref!
    }

    deinit { CCCryptorRelease(ref) }

    /// Block modes need whole blocks; CTR accepts any length and may run in place.
    func update(_ input: UnsafeRawPointer, into output: UnsafeMutableRawPointer, count: Int) {
        var moved = 0
        let status = CCCryptorUpdate(ref, input, count, output, count, &moved)
        precondition(status == kCCSuccess && moved == count, "AES update failed")
    }

    func update(_ buffer: UnsafeMutableRawBufferPointer) {
        guard let base = buffer.baseAddress else { return }
        update(base, into: base, count: buffer.count)
    }

    func reset(iv: AESBlock) {
        var iv = iv
        CCCryptorReset(ref, &iv)
    }

    func callAsFunction(_ block: AESBlock) -> AESBlock {
        var input = block
        var output = AESBlock()
        update(&input, into: &output, count: 16)
        return output
    }
}

enum AES {
    static func encrypt(_ block: AESBlock, key: AESBlock) -> AESBlock {
        Cryptor(kCCEncrypt, mode: kCCModeECB, key: key)(block)
    }

    static func decrypt(_ block: AESBlock, key: AESBlock) -> AESBlock {
        Cryptor(kCCDecrypt, mode: kCCModeECB, key: key)(block)
    }

    /// ECB/CBC over whole blocks; CommonCrypto forbids these modes in place, hence two buffers.
    static func crypt(
        _ operation: Int, mode: Int, key: AESBlock, iv: AESBlock = .zero,
        _ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawPointer
    ) {
        precondition(input.count % 16 == 0, "block modes need whole blocks")
        guard let base = input.baseAddress else { return }
        Cryptor(operation, mode: mode, key: key, iv: iv).update(base, into: output, count: input.count)
    }

    static func crypt(_ operation: Int, mode: Int, key: AESBlock, iv: AESBlock = .zero, _ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var output = Data(count: data.count)
        output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { crypt(operation, mode: mode, key: key, iv: iv, $0, into: out.baseAddress!) }
        }
        return output
    }
}

enum PBKDF2 {
    static func sha512(password: Data, salt: Data, iterations: Int, length: Int) -> Data {
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
