import Foundation
#if canImport(OrbitDiagnosticsKit)
import OrbitDiagnosticsKit
#endif

/// Orbit's hosted applets use its paired-phone journal. Exported hosts use their
/// own fixed container journal, collected by Orbit Mac over native CoreDevice.
public enum OrbitAppletDiagnostics {
    public static func record(_ name: String, _ fields: [String: String]) {
        #if canImport(OrbitDiagnosticsKit)
        let journal = OrbitDiagnostics.shared
        #else
        let journal = OrbitAppDiagnostics.journal
        #endif
        journal.record("applet", name, fields.merging(OrbitAppDiagnostics.metadata) { original, _ in original })
    }
}
