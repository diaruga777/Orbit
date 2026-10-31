import Foundation

/// Drop these diagnostic sources into an iOS target, or import OrbitDiagnosticsKit.
/// Developer labels only: this is not a recorder of user content.
public enum OrbitAppDiagnostics {
    public static let containerPath = "Library/Application Support/OrbitAppDiagnostics"
    public static let journal = OrbitDiagnostics.store(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrbitAppDiagnostics"))
    public static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0))
        }
    }
    public static func record(_ category: String, _ name: String) {
        guard validLabel(category), validLabel(name) else { return }
        journal.record(category, name, ["bundle": Bundle.main.bundleIdentifier ?? "unknown",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""])
    }
    public static func action(_ name: String) { record("action", name) }
    public static func screen(_ name: String) { record("screen", name) }
    /// Error domain/code avoid accidentally persisting user data in descriptions.
    public static func failure(_ operation: String, _ error: Error) {
        guard validLabel(operation) else { return }
        let error = error as NSError
        journal.record("error", operation, ["errorDomain": error.domain, "errorCode": String(error.code)])
    }
}
