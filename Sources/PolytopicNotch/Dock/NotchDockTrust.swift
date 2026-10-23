import AppKit
import Foundation
import Security

/// Decides whether a claimed pid may dock. `NotchDock` asks once per pid and keeps the verdict until that process
/// exits. Implementations must not block the main actor.
public protocol NotchDockTrust: Sendable {
    func verify(pid: Int32) async -> Bool
}

/// The default check: the pid is a running app signed with a certificate Apple issued for shipping Mac apps
/// (Developer ID Application, or Mac App Store), any team. Ad hoc and unsigned code never docks. Apple Development
/// certificates are admitted only when `admitsDevelopment` is on (DEBUG builds turn it on, so a developer's own
/// Debug builds dock with each other and with released apps).
///
/// It isn't strong authentication: any local process can *claim* a trusted pid in a message. A spoof, or a signed
/// app that behaves badly, can at most make other pills step aside; an app that isn't granted the notch asks its
/// question in its floating window, so a question is never hidden, and messages carry no content. The user's answer
/// to a bad app is the block list (`NotchDock.setBlocked`). Off the main actor, a few ms per pid.
public struct DeveloperIDTrust: NotchDockTrust {
    /// Developer ID Application (leaf marker 1.2.840.113635.100.6.1.13, under the Developer ID intermediate
    /// 1.2.840.113635.100.6.2.6) or Mac App Store (leaf marker 1.2.840.113635.100.6.1.9).
    public static let releaseRequirement = """
        anchor apple generic and ((certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
        certificate leaf[field.1.2.840.113635.100.6.1.13] exists) or certificate leaf[field.1.2.840.113635.100.6.1.9] exists)
        """
    /// Apple Development (leaf marker 1.2.840.113635.100.6.1.12).
    public static let developmentRequirement = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.12] exists"

    public var admitsDevelopment: Bool
    #if DEBUG
    /// DEBUG builds only: also admit ad hoc signed processes, for local test builds and the stand-in peer. Compiled
    /// out of Release, where `hasAdHocOverride` is false (a test checks).
    public var allowAdHocForTesting = false
    public static let hasAdHocOverride = true
    #else
    public static let hasAdHocOverride = false
    #endif

    public init(admitsDevelopment: Bool = Self.developmentDefault) {
        self.admitsDevelopment = admitsDevelopment
    }

    #if DEBUG
    public static let developmentDefault = true
    #else
    public static let developmentDefault = false
    #endif

    public func verify(pid: Int32) async -> Bool {
        let check = self
        return await Task.detached(priority: .utility) { check.check(pid: pid) }.value
    }

    /// The synchronous check. Call it off the main thread.
    public func check(pid: Int32) -> Bool {
        guard let code = SecCodeLookup.code(pid: pid) else { return false }
        if SecCodeLookup.satisfies(code, Self.releaseRequirement) { return true }
        if admitsDevelopment, SecCodeLookup.satisfies(code, Self.developmentRequirement) { return true }
        #if DEBUG
        if allowAdHocForTesting, SecCodeCheckValidity(code, [], nil) == errSecSuccess { return true }
        #endif
        return false
    }
}

enum SecCodeLookup {
    static func code(pid: Int32) -> SecCode? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }

    static func satisfies(_ code: SecCode, _ text: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

/// A narrower check for a developer who wants only their own apps in their dock: the pid's signature satisfies
/// `anchor apple generic and certificate leaf[subject.OU] = "<teamID>"` (Developer ID or Apple Development, that
/// team), and its running application's bundle ID starts with `bundlePrefix` (empty: any). Use it with a channel
/// prefix of your own (`DistributedNotchDockChannel.Options.prefix`) so your apps don't meet the shared dock at all.
public struct CodeSignatureTrust: NotchDockTrust {
    public let teamID: String
    public let bundlePrefix: String
    #if DEBUG
    /// DEBUG builds only: also admit ad-hoc signed processes (with the bundle prefix), for local test builds and the
    /// stand-in peer. Compiled out of Release, where `hasAdHocOverride` is false (a test checks).
    public var allowAdHocForTesting = false
    public static let hasAdHocOverride = true
    #else
    public static let hasAdHocOverride = false
    #endif

    public init(teamID: String, bundlePrefix: String = "") {
        self.teamID = teamID
        self.bundlePrefix = bundlePrefix
    }

    public func verify(pid: Int32) async -> Bool {
        let check = self
        // Off the main actor: SecCode calls talk to the kernel and may read the binary.
        return await Task.detached(priority: .utility) { check.check(pid: pid) }.value
    }

    /// The synchronous check. Call it off the main thread.
    public func check(pid: Int32) -> Bool {
        signatureMatches(pid: pid) && bundleMatches(pid: pid)
    }

    public func signatureMatches(pid: Int32) -> Bool {
        guard let code = SecCodeLookup.code(pid: pid) else { return false }
        if SecCodeLookup.satisfies(code, "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"") { return true }
        #if DEBUG
        if allowAdHocForTesting, SecCodeCheckValidity(code, [], nil) == errSecSuccess { return true }
        #endif
        return false
    }

    public func bundleMatches(pid: Int32) -> Bool {
        // NSRunningApplication is documented thread-safe for reading its properties.
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              let id = app.bundleIdentifier else { return false }
        return id.hasPrefix(bundlePrefix)
    }
}

/// Trusts a fixed set of pids (or every pid): tests and previews, never an app.
public struct NotchDockStaticTrust: NotchDockTrust {
    /// `nil`: everyone.
    public var trusted: Set<Int32>?

    public init(trusted: Set<Int32>?) {
        self.trusted = trusted
    }

    public func verify(pid: Int32) async -> Bool { trusted?.contains(pid) ?? true }
}
