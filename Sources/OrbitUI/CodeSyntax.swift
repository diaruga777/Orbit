#if os(iOS)
import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax
import OrbitCore

enum CodeSyntax {
    static func diagnostics(text: String) -> [CodeDiagnostic] {
        let tree = Parser.parse(source: text)
        let converter = SourceLocationConverter(fileName: "editor.swift", tree: tree)
        return ParseDiagnosticsGenerator.diagnostics(for: tree).prefix(100).map {
            let location = $0.location(converter: converter)
            return CodeDiagnostic(line: location.line - 1, character: location.column - 1, message: $0.message)
        }
    }
}
#endif
