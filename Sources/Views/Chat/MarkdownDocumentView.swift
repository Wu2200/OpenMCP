import SwiftUI
import UIKit

enum MarkdownBlock: Identifiable {
    case heading(id: Int, level: Int, text: String)
    case paragraph(id: Int, text: String)
    case list(id: Int, items: [MarkdownListItem])
    case blockquote(id: Int, text: String)
    case codeBlock(id: Int, language: String, code: String)
    case table(id: Int, headers: [String], alignments: [HorizontalAlignment], rows: [[String]])
    case divider(id: Int)

    var id: Int {
        switch self {
        case .heading(let id, _, _): return id
        case .paragraph(let id, _): return id
        case .list(let id, _): return id
        case .blockquote(let id, _): return id
        case .codeBlock(let id, _, _): return id
        case .table(let id, _, _, _): return id
        case .divider(let id): return id
        }
    }
}

struct MarkdownListItem: Identifiable {
    enum Marker {
        case bullet
        case ordered(String)
        case task(Bool)
    }

    let id: Int
    let indent: Int
    let marker: Marker
    var text: String
}

struct MarkdownDocumentView: View {
    let content: String
    let theme: AppThemePalette

    var body: some View {
        let blocks = MarkdownParser.parse(content)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                switch block {
                case .heading(_, let level, let text):
                    headingView(level: level, text: text)

                case .paragraph(_, let text):
                    MarkdownInlineText(text: text, fontSize: 15.5, weight: .regular, theme: theme)
                        .lineSpacing(5)

                case .list(_, let items):
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(items) { item in
                            listItemView(item)
                        }
                    }
                    .padding(.vertical, 2)

                case .blockquote(_, let text):
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(theme.accent.opacity(0.75))
                            .frame(width: 3.5)

                        MarkdownInlineText(text: text, fontSize: 14.5, weight: .regular, theme: theme, isSecondary: true)
                            .lineSpacing(4)
                            .padding(.leading, 12)
                            .padding(.vertical, 6)
                    }
                    .padding(.trailing, 10)
                    .background(theme.elevatedBackground.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                case .codeBlock(_, let language, let code):
                    CodeBlockCard(language: language, code: code, theme: theme)

                case .table(_, let headers, let alignments, let rows):
                    MarkdownTableView(headers: headers, alignments: alignments, rows: rows, theme: theme)

                case .divider:
                    Rectangle()
                        .fill(theme.border)
                        .frame(height: 1)
                        .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        let size: CGFloat = {
            switch level {
            case 1: return 20.5
            case 2: return 18.0
            case 3: return 16.5
            default: return 15.5
            }
        }()

        VStack(alignment: .leading, spacing: 6) {
            MarkdownInlineText(text: text, fontSize: size, weight: .bold, theme: theme)
                .lineSpacing(3)

            if level == 1 {
                Rectangle()
                    .fill(theme.border.opacity(0.6))
                    .frame(height: 1)
            }
        }
        .padding(.top, level <= 2 ? 6 : 3)
        .padding(.bottom, 1)
    }

    @ViewBuilder
    private func listItemView(_ item: MarkdownListItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch item.marker {
            case .bullet:
                Text(item.indent == 0 ? "•" : (item.indent == 1 ? "◦" : "▪"))
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundColor(theme.primaryText)
                    .frame(width: 14, alignment: .center)

            case .ordered(let num):
                Text(num)
                    .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.primaryText)
                    .frame(minWidth: 18, alignment: .trailing)

            case .task(let checked):
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(checked ? theme.accent : theme.secondaryText)
                    .frame(width: 16, alignment: .center)
            }

            MarkdownInlineText(text: item.text, fontSize: 15.5, weight: .regular, theme: theme)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(min(item.indent, 4)) * 16)
    }
}

struct MarkdownInlineText: View {
    let text: String
    var fontSize: CGFloat = 15.5
    var weight: Font.Weight = .regular
    let theme: AppThemePalette
    var isSecondary: Bool = false

    var body: some View {
        Text(buildAttributedString())
            .font(.system(size: fontSize, weight: weight))
            .foregroundColor(isSecondary ? theme.secondaryText : theme.primaryText)
            .tint(theme.accent)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buildAttributedString() -> AttributedString {
        let prepared = MarkdownParser.enrichAutoLinksAndSpaces(text)
        guard var attr = try? AttributedString(
            markdown: prepared,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(text)
        }

        let codeBg = UIColor(theme.elevatedBackground)
        let codeFg = UIColor(theme.primaryText)
        let linkFg = UIColor(theme.accent)

        for run in attr.runs {
            let range = run.range
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attr[range].font = .system(size: max(12.5, fontSize - 1.5), weight: .medium, design: .monospaced)
                attr[range].backgroundColor = codeBg
                attr[range].foregroundColor = codeFg
            }
            if run.link != nil {
                attr[range].foregroundColor = linkFg
                attr[range].underlineStyle = .single
            }
        }
        return attr
    }
}

struct MarkdownTableView: View {
    let headers: [String]
    let alignments: [HorizontalAlignment]
    let rows: [[String]]
    let theme: AppThemePalette

    private var columnCount: Int {
        max(headers.count, rows.map { $0.count }.max() ?? 0)
    }

    private var columnWidths: [CGFloat] {
        guard columnCount > 0 else { return [] }
        var widths: [CGFloat] = []
        for col in 0..<columnCount {
            let headerText = col < headers.count ? MarkdownParser.stripInlineSyntax(headers[col]) : ""
            var maxUnits = MarkdownParser.visualWidth(of: headerText)
            for row in rows where col < row.count {
                let cellText = MarkdownParser.stripInlineSyntax(row[col])
                maxUnits = max(maxUnits, MarkdownParser.visualWidth(of: cellText))
            }

            let calculated: CGFloat
            if maxUnits <= 3 {
                calculated = 48
            } else if maxUnits <= 8 {
                calculated = max(68, CGFloat(maxUnits) * 10.5 + 24)
            } else if maxUnits <= 18 {
                calculated = min(155, max(92, CGFloat(maxUnits) * 8.8 + 24))
            } else {
                calculated = min(230, max(155, CGFloat(maxUnits) * 6.5 + 28))
            }
            widths.append(calculated)
        }

        let screenAvailable = max(300, UIScreen.main.bounds.width - 36)
        let total = widths.reduce(0, +)
        if total > 0 && total < screenAvailable {
            let scale = screenAvailable / total
            return widths.map { floor($0 * scale) }
        }
        return widths
    }

    var body: some View {
        let widths = columnWidths
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                tableRowView(cells: headers, widths: widths, isHeader: true)

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    Rectangle()
                        .fill(theme.border)
                        .frame(height: 1)

                    tableRowView(
                        cells: row,
                        widths: widths,
                        isHeader: false,
                        isAlternate: rowIndex % 2 == 1
                    )
                }
            }
            .background(theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func tableRowView(
        cells: [String],
        widths: [CGFloat],
        isHeader: Bool,
        isAlternate: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { col in
                let cellText = col < cells.count ? cells[col] : ""
                let width = col < widths.count ? widths[col] : 100
                let align = col < alignments.count ? alignments[col] : .leading

                cellContent(text: cellText, isHeader: isHeader, alignment: align)
                    .padding(.horizontal, 11)
                    .padding(.vertical, isHeader ? 11 : 10)
                    .frame(width: width, alignment: frameAlignment(for: align))
                    .frame(maxHeight: .infinity, alignment: frameAlignment(for: align))

                if col < columnCount - 1 {
                    Rectangle()
                        .fill(theme.border)
                        .frame(width: 1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(
            isHeader
                ? theme.elevatedBackground
                : (isAlternate ? theme.elevatedBackground.opacity(0.28) : theme.cardBackground)
        )
    }

    @ViewBuilder
    private func cellContent(text: String, isHeader: Bool, alignment: HorizontalAlignment) -> some View {
        let prepared = MarkdownParser.enrichAutoLinksAndSpaces(text)
        if var attr = try? AttributedString(
            markdown: prepared,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            let _ = styleCellAttributedString(&attr, isHeader: isHeader)
            Text(attr)
                .font(.system(size: isHeader ? 13.5 : 14, weight: isHeader ? .semibold : .regular))
                .foregroundColor(theme.primaryText)
                .tint(theme.accent)
                .multilineTextAlignment(textAlignment(for: alignment))
                .lineSpacing(3)
                .textSelection(.enabled)
        } else {
            Text(text)
                .font(.system(size: isHeader ? 13.5 : 14, weight: isHeader ? .semibold : .regular))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(textAlignment(for: alignment))
                .lineSpacing(3)
                .textSelection(.enabled)
        }
    }

    private func styleCellAttributedString(_ attr: inout AttributedString, isHeader: Bool) {
        let codeBg = UIColor(theme.elevatedBackground)
        let codeFg = UIColor(theme.primaryText)
        let linkFg = UIColor(theme.accent)

        for run in attr.runs {
            let range = run.range
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attr[range].font = .system(size: 12.5, weight: .medium, design: .monospaced)
                attr[range].backgroundColor = codeBg
                attr[range].foregroundColor = codeFg
            }
            if run.link != nil {
                attr[range].foregroundColor = linkFg
                attr[range].underlineStyle = .single
            }
        }
    }

    private func frameAlignment(for align: HorizontalAlignment) -> Alignment {
        switch align {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    private func textAlignment(for align: HorizontalAlignment) -> TextAlignment {
        switch align {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }
}

enum MarkdownParser {
    static func parse(_ raw: String) -> [MarkdownBlock] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var nextId = 1

        var i = 0
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.paragraph(id: nextId, text: joined))
                nextId += 1
            }
            paragraphBuffer.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 1. Blank line -> flush current paragraph
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // 2. Fenced Code Block (``` or ~~~)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let langRaw = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let lang = langRaw.isEmpty ? "code" : langRaw
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(id: nextId, language: lang, code: codeLines.joined(separator: "\n")))
                nextId += 1
                continue
            }

            // 3. Markdown Table
            if i + 1 < lines.count,
               line.contains("|"),
               let alignments = parseTableSeparator(lines[i + 1]) {
                let headerCells = splitTableRow(line)
                if !headerCells.isEmpty {
                    flushParagraph()
                    i += 2
                    var rows: [[String]] = []
                    while i < lines.count {
                        let rowLine = lines[i]
                        let rowTrimmed = rowLine.trimmingCharacters(in: .whitespaces)
                        if rowTrimmed.isEmpty || !rowLine.contains("|") || rowTrimmed.hasPrefix("```") || rowTrimmed.hasPrefix("#") {
                            break
                        }
                        if parseTableSeparator(rowLine) != nil {
                            i += 1
                            continue
                        }
                        let cells = splitTableRow(rowLine)
                        if !cells.isEmpty {
                            rows.append(cells)
                        }
                        i += 1
                    }
                    blocks.append(.table(id: nextId, headers: headerCells, alignments: alignments, rows: rows))
                    nextId += 1
                    continue
                }
            }

            // 4. Horizontal Divider (---, ***, ___)
            if isHorizontalRule(trimmed) {
                flushParagraph()
                blocks.append(.divider(id: nextId))
                nextId += 1
                i += 1
                continue
            }

            // 5. Heading (# to ######)
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(id: nextId, level: heading.level, text: heading.text))
                nextId += 1
                i += 1
                continue
            }

            // 6. Blockquote (> ...)
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while i < lines.count {
                    let qTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if qTrimmed.hasPrefix(">") {
                        var dropped = String(qTrimmed.dropFirst())
                        if dropped.hasPrefix(" ") {
                            dropped.removeFirst()
                        }
                        quoteLines.append(dropped)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.blockquote(id: nextId, text: quoteLines.joined(separator: "\n")))
                nextId += 1
                continue
            }

            // 7. Unordered / Ordered / Task List
            if let firstItem = parseListItem(line, id: 0) {
                flushParagraph()
                var items: [MarkdownListItem] = [firstItem]
                i += 1
                var itemCounter = 1
                while i < lines.count {
                    let nextLine = lines[i]
                    let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.isEmpty {
                        break
                    }
                    if let parsedItem = parseListItem(nextLine, id: itemCounter) {
                        items.append(parsedItem)
                        itemCounter += 1
                        i += 1
                    } else if nextLine.hasPrefix("  ") || nextLine.hasPrefix("\t"),
                              !nextTrimmed.hasPrefix("#"),
                              !nextTrimmed.hasPrefix("```"),
                              !nextTrimmed.hasPrefix("|") {
                        items[items.count - 1].text += "\n" + nextTrimmed
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(id: nextId, items: items))
                nextId += 1
                continue
            }

            // 8. Normal paragraph line
            paragraphBuffer.append(line)
            i += 1
        }

        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for ch in trimmed {
            if ch == "#" {
                level += 1
            } else {
                break
            }
        }
        guard level >= 1 && level <= 6 else { return nil }
        let remainder = String(trimmed.dropFirst(level))
        guard remainder.first == " " || remainder.first == "\t" || remainder.unicodeScalars.first.map({ $0.value > 127 }) == true else {
            return nil
        }
        let cleaned = remainder
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
        guard !cleaned.isEmpty else { return nil }
        return (level, cleaned)
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        if compact.allSatisfy({ $0 == "-" }) || compact.allSatisfy({ $0 == "*" }) || compact.allSatisfy({ $0 == "_" }) {
            return true
        }
        return false
    }

    private static func parseListItem(_ line: String, id: Int) -> MarkdownListItem? {
        var leadingSpaces = 0
        for ch in line {
            if ch == " " {
                leadingSpaces += 1
            } else if ch == "\t" {
                leadingSpaces += 2
            } else {
                break
            }
        }
        let indent = leadingSpaces / 2
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Task list: - [ ] or - [x]
        if let match = trimmed.range(of: #"^[-*+]\s+\[([ xX])\]\s+"#, options: .regularExpression) {
            let prefix = String(trimmed[match])
            let checked = prefix.contains("x") || prefix.contains("X")
            let body = String(trimmed[match.upperBound...])
            return MarkdownListItem(id: id, indent: indent, marker: .task(checked), text: body)
        }

        // Unordered list: -, *, +, •
        if let match = trimmed.range(of: #"^[-*+•]\s+"#, options: .regularExpression) {
            let body = String(trimmed[match.upperBound...])
            return MarkdownListItem(id: id, indent: indent, marker: .bullet, text: body)
        }

        // Ordered list: 1. or 1)
        if let match = trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            let markerStr = String(trimmed[match]).trimmingCharacters(in: .whitespaces)
            let body = String(trimmed[match.upperBound...])
            return MarkdownListItem(id: id, indent: indent, marker: .ordered(markerStr), text: body)
        }

        return nil
    }

    private static func parseTableSeparator(_ line: String) -> [HorizontalAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") && trimmed.contains("-") else { return nil }
        let cells = splitTableRow(trimmed)
        guard !cells.isEmpty else { return nil }

        var alignments: [HorizontalAlignment] = []
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard c.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else {
                return nil
            }
            if c.hasPrefix(":") && c.hasSuffix(":") {
                alignments.append(.center)
            } else if c.hasSuffix(":") {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return alignments
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var working = line.trimmingCharacters(in: .whitespaces)
        if working.hasPrefix("|") {
            working.removeFirst()
        }
        if working.hasSuffix("|") && !working.hasSuffix("\\|") {
            working.removeLast()
        }

        let placeholder = "\u{FFFF}"
        let safe = working.replacingOccurrences(of: "\\|", with: placeholder)
        return safe.components(separatedBy: "|").map {
            $0.replacingOccurrences(of: placeholder, with: "|").trimmingCharacters(in: .whitespaces)
        }
    }

    static func enrichAutoLinksAndSpaces(_ input: String) -> String {
        let lines = input.components(separatedBy: "\n")
        let processedLines = lines.map { line -> String in
            var leadingCount = 0
            for ch in line {
                if ch == " " {
                    leadingCount += 1
                } else if ch == "\t" {
                    leadingCount += 2
                } else {
                    break
                }
            }
            if leadingCount > 0 {
                let nbsp = String(repeating: "\u{00A0}", count: leadingCount)
                let rest = line.drop(while: { $0 == " " || $0 == "\t" })
                return nbsp + rest
            }
            return line
        }

        var joined = processedLines.joined(separator: "\n")

        // Auto-link bare github.com/owner/repo if not already inside markdown link or code
        if !joined.contains("](") && !joined.contains("`") {
            joined = joined.replacingOccurrences(
                of: #"(?<![/\w])(github\.com/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)?)"#,
                with: "[$1](https://$1)",
                options: .regularExpression
            )
        }
        return joined
    }

    static func stripInlineSyntax(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func visualWidth(of text: String) -> Double {
        var total = 0.0
        for scalar in text.unicodeScalars {
            if scalar.value > 0x2E80 {
                total += 1.85
            } else {
                total += 1.0
            }
        }
        return total
    }
}
