import Foundation

/// Flattens the markdown coding agents write into text that reads correctly in
/// a notification banner and in the inbox.
///
/// Agents answer in markdown because their usual home is a terminal that
/// renders it. A notification banner renders nothing, so `**Done!**` arrives
/// with its asterisks showing and a fenced code block arrives as a wall of
/// backticks. Everything here is display-only and is never applied to a command
/// the user is being asked to approve — those are shown exactly as they were
/// sent, always.
public enum PlainText {
    /// Markdown in, readable prose out. Structure is preserved: paragraphs stay
    /// separate and list items stay on their own lines.
    public static func fromMarkdown(_ text: String) -> String {
        var out = text

        // Fenced blocks first, before inline rules can chew on their contents.
        // The code inside is kept — it is usually the substance of the message.
        out = out.replacingOccurrences(of: #"(?m)^\s*```[^\n]*$"#, with: "",
                                       options: .regularExpression)

        for (pattern, replacement) in [
            // Images before links: the alt text is the only readable part.
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),
            // Bare autolinks: <https://…>
            (#"<(https?://[^>\s]+)>"#, "$1"),
            (#"`([^`]*)`"#, "$1"),
            (#"~~(.*?)~~"#, "$1"),
            (#"\*\*(.*?)\*\*"#, "$1"),
            // Single-asterisk emphasis only when it wraps real content, so a
            // stray `*` in prose is left alone.
            (#"\*([^*\s][^*]*?)\*"#, "$1"),
            // Underscores are deliberately untouched: stripping them would eat
            // the ones in real identifiers like __init__.py.
            (#"(?m)^\s{0,3}#{1,6}\s+"#, ""),
            (#"(?m)^\s{0,3}>\s?"#, ""),
            // Horizontal rules carry nothing once the styling is gone.
            (#"(?m)^\s{0,3}([-*_])(\s*\1){2,}\s*$"#, ""),
            // Table pipes and separator rows.
            (#"(?m)^\s*\|[-\s|:]+\|\s*$"#, ""),
            (#"(?m)^\s*[-*+]\s+"#, "• "),
            (#"(?m)^\s*(\d+)\.\s+"#, "$1. "),
            // Trailing whitespace, then runs of blank lines.
            (#"(?m)[ \t]+$"#, ""),
            (#"\n{3,}"#, "\n\n"),
        ] {
            out = out.replacingOccurrences(of: pattern, with: replacement,
                                           options: .regularExpression)
        }

        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same flattening, then squeezed onto one line for a notification
    /// banner, which shows a couple of lines at most and treats a newline as a
    /// hard stop — so a summary whose first line is "Done." would arrive saying
    /// nothing at all.
    public static func singleLine(_ text: String, limit: Int = 240) -> String {
        let flattened = fromMarkdown(text)
            .replacingOccurrences(of: #"\s*\n+\s*"#, with: "  ", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncate(flattened, limit: limit)
    }

    /// Cuts at a word boundary where there is one nearby, so the tail is not
    /// left mid-word.
    public static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: space, to: cut.endIndex) < 24 {
            return cut[..<space].trimmingCharacters(in: .whitespaces) + "…"
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}
