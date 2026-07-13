import CryptoKit
import Darwin
import Foundation
import Security

struct HelperConfiguration {
    let allowedUID: uid_t
    let executableSHA256: String
    let appExecutablePath: String

    static func load(from path: String = MacFanHelperConstants.configurationPath) throws -> HelperConfiguration {
        var fileStatus = stat()
        guard Darwin.lstat(path, &fileStatus) == 0,
              fileStatus.st_uid == 0,
              fileStatus.st_gid == 0,
              (fileStatus.st_mode & 0o077) == 0 else {
            throw CocoaError(.fileReadNoPermission)
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = value as? [String: Any],
              let uidNumber = dictionary["AllowedUID"] as? NSNumber,
              let digest = dictionary["ExecutableSHA256"] as? String,
              let executablePath = dictionary["AppExecutablePath"] as? String,
              let protocolVersion = dictionary["ProtocolVersion"] as? NSNumber,
              protocolVersion.intValue == MacFanHelperConstants.protocolVersion,
              digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let canonicalPath = URL(fileURLWithPath: executablePath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        return HelperConfiguration(
            allowedUID: uid_t(uidNumber.uint32Value),
            executableSHA256: digest,
            appExecutablePath: canonicalPath
        )
    }
}

enum ClientAuthenticationFailure: Error, LocalizedError {
    case wrongUser
    case processPathUnavailable
    case unexpectedExecutable
    case digestMismatch
    case invalidCodeSignature
    case bundleIdentifierMismatch

    var errorDescription: String? {
        switch self {
        case .wrongUser: "The caller is not the user who installed MacFan."
        case .processPathUnavailable: "The caller executable could not be identified."
        case .unexpectedExecutable: "The caller is not a MacFan application executable."
        case .digestMismatch: "The caller does not match the app authorized by the installer."
        case .invalidCodeSignature: "The caller has an invalid code signature."
        case .bundleIdentifierMismatch: "The caller has an unexpected bundle identifier."
        }
    }
}

/// Pins XPC access to the exact app executable installed alongside this
/// helper, its ad-hoc code identifier, and the installing user's effective UID.
/// Even an authenticated caller receives only the bounded semantic protocol.
final class ClientAuthenticator {
    private let configuration: HelperConfiguration

    init(configuration: HelperConfiguration) {
        self.configuration = configuration
    }

    func validate(_ connection: NSXPCConnection) throws {
        guard connection.effectiveUserIdentifier == configuration.allowedUID else {
            throw ClientAuthenticationFailure.wrongUser
        }
        var consoleStatus = stat()
        guard Darwin.lstat("/dev/console", &consoleStatus) == 0,
              consoleStatus.st_uid == configuration.allowedUID else {
            throw ClientAuthenticationFailure.wrongUser
        }
        let pid = connection.processIdentifier
        guard pid > 0, let executableURL = executableURL(for: pid) else {
            throw ClientAuthenticationFailure.processPathUnavailable
        }

        let resolvedPath = executableURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedPath == configuration.appExecutablePath,
              resolvedPath.hasSuffix("/MacFan.app/Contents/MacOS/MacFan") else {
            throw ClientAuthenticationFailure.unexpectedExecutable
        }
        var executableStatus = stat()
        guard Darwin.lstat(resolvedPath, &executableStatus) == 0,
              executableStatus.st_uid == configuration.allowedUID,
              (executableStatus.st_mode & 0o022) == 0 else {
            throw ClientAuthenticationFailure.unexpectedExecutable
        }
        let data = try Data(contentsOf: executableURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == configuration.executableSHA256 else {
            throw ClientAuthenticationFailure.digestMismatch
        }

        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess else {
            throw ClientAuthenticationFailure.invalidCodeSignature
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            throw ClientAuthenticationFailure.invalidCodeSignature
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              dictionary[kSecCodeInfoIdentifier as String] as? String == MacFanHelperConstants.appBundleIdentifier else {
            throw ClientAuthenticationFailure.bundleIdentifierMismatch
        }
    }

    private func executableURL(for pid: pid_t) -> URL? {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
    }
}
