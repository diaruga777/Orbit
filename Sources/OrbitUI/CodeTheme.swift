#if os(iOS)
import UIKit
import Runestone

final class CodeTheme: Theme {
    let font: UIFont
    init(size: CGFloat) { font = .monospacedSystemFont(ofSize: size, weight: .regular) }
    var textColor: UIColor { .label }
    var gutterBackgroundColor: UIColor { .secondarySystemBackground }
    var gutterHairlineColor: UIColor { .separator.withAlphaComponent(0.25) }
    var lineNumberColor: UIColor { .tertiaryLabel }
    var lineNumberFont: UIFont { .monospacedSystemFont(ofSize: max(11, font.pointSize - 2), weight: .regular) }
    var selectedLineBackgroundColor: UIColor { .systemBlue.withAlphaComponent(0.055) }
    var selectedLinesLineNumberColor: UIColor { .secondaryLabel }
    var selectedLinesGutterBackgroundColor: UIColor { .systemBlue.withAlphaComponent(0.08) }
    var invisibleCharactersColor: UIColor { .tertiaryLabel }
    var pageGuideHairlineColor: UIColor { .separator }
    var pageGuideBackgroundColor: UIColor { .clear }
    var markedTextBackgroundColor: UIColor { .systemBlue.withAlphaComponent(0.15) }
    func textColor(for highlightName: String) -> UIColor? {
        if highlightName.hasPrefix("comment") { return .systemGray }
        if highlightName.hasPrefix("keyword") || highlightName.hasPrefix("include") { return .systemPink }
        if highlightName.hasPrefix("string") { return .systemRed }
        if highlightName.hasPrefix("type") || highlightName.hasPrefix("constructor") { return .systemTeal }
        if highlightName.hasPrefix("function") { return .systemPurple }
        if highlightName.hasPrefix("number") || highlightName.hasPrefix("constant") { return .systemOrange }
        if highlightName.hasPrefix("property") { return .systemIndigo }
        return nil
    }
}

/// Keep the familiar native editing and selection machinery; only intercept
/// completion navigation while its menu is visible.
final class CodeTextView: TextView {
    var completionCommand: ((String) -> Void)?
    var hasCompletions = false
    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        if hasCompletions {
            for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\t", "\r", UIKeyCommand.inputEscape] {
                let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(completionKey(_:)))
                command.wantsPriorityOverSystemBehavior = true; commands.append(command)
            }
        }
        return commands
    }
    @objc private func completionKey(_ command: UIKeyCommand) { completionCommand?(command.input ?? "") }
}
#endif
