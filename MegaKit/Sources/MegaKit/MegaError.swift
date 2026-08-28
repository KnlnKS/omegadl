import Foundation

public enum MegaAPIError: Int, Error, Sendable, Hashable {
    case internalError = -1
    case badArguments = -2
    case again = -3
    case rateLimited = -4
    case failed = -5
    case tooMany = -6
    case outOfRange = -7
    case expired = -8
    case notFound = -9
    case circular = -10
    case accessDenied = -11
    case alreadyExists = -12
    case incomplete = -13
    case badKey = -14
    case badSession = -15
    case blocked = -16
    case overQuota = -17
    case temporarilyUnavailable = -18
    case tooManyConnections = -19
    case writeFailed = -20
    case readFailed = -21
    case appKeyInvalid = -22
    case sslVerifyFailed = -23
    case goingOverQuota = -24
    case rolledBack = -25
    case multiFactorRequired = -26
    case masterOnly = -27
    case businessPastDue = -28
    case payWall = -29
}

public enum MegaError: Error, Sendable, Hashable {
    case api(MegaAPIError)
    case unrecognizedAPICode(Int)
    case malformedResponse
    case httpStatus(Int)
    case bandwidthExceeded(retryAfter: TimeInterval?)
    case invalidLink
    case decryptionFailed
    case integrityCheckFailed
    case notAuthenticated
    case proofOfWorkFailed

    static func apiCode(_ code: Int) -> MegaError {
        MegaAPIError(rawValue: code).map(MegaError.api) ?? .unrecognizedAPICode(code)
    }
}

extension MegaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .api(.notFound): "That item no longer exists on MEGA."
        case .api(.accessDenied): "You do not have permission to access that item."
        case .api(.badSession): "Your session expired. Sign in again."
        case .api(.multiFactorRequired): "This account requires a two-factor code."
        case .api(.overQuota), .api(.goingOverQuota): "The account is over its storage quota."
        case .api(.blocked): "This account has been blocked."
        case .api(.rateLimited), .api(.tooMany): "MEGA is rate limiting this connection. Try again shortly."
        case .api(let error): "MEGA returned error \(error.rawValue)."
        case .unrecognizedAPICode(let code): "MEGA returned unknown error \(code)."
        case .malformedResponse: "MEGA returned a response OmegaDL could not read."
        case .httpStatus(let code): "The transfer server returned HTTP \(code)."
        case .bandwidthExceeded: "MEGA's bandwidth limit for this link has been reached."
        case .invalidLink: "That does not look like a MEGA link."
        case .decryptionFailed: "The decryption key does not match this item."
        case .integrityCheckFailed: "The downloaded data failed its integrity check."
        case .notAuthenticated: "Sign in to do that."
        case .proofOfWorkFailed: "Could not satisfy MEGA's anti-abuse challenge."
        }
    }
}
