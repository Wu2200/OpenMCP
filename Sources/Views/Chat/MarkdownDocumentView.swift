import SwiftUI
import UIKit

enum MarkdownBlock: Identifiable, Equatable {
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

struct MarkdownListItem: Identifiable, Equatable {
    enum Marker: Equatable {
        case bullet
        case ordered(String)
        case task(Bool)
    }

    let id: Int
    let indent: Int
    let marker: Marker
    var text: String
}

final class MarkdownRenderCache {
    static let shared = MarkdownRenderCache()

    private let blockCache = NSCache<NSString, BlockBox>()
    private let attrCache = NSCache<NSString, AttrBox>()

    final class BlockBox {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    final class AttrBox {
        let attr: AttributedString
        init(_ attr: AttributedString) { self.attr = attr }
    }

    private init() {
        blockCache.countLimit = 80
        attrCache.countLimit = 400
    }

    func blocks(for content: String, isStreaming: Bool = false) -> [MarkdownBlock] {
        if isStreaming || content.utf8.count > 12_000 {
            return MarkdownParser.parse(content)
        }
        let key = content as NSString
        if let cached = blockCache.object(forKey: key) {
            return cached.blocks
        }
        let parsed = MarkdownParser.parse(content)
        blockCache.setObject(BlockBox(parsed), forKey: key)
        return parsed
    }

    func attributedString(
        for text: String,
        fontSize: CGFloat,
        weight: Font.Weight = .regular,
        theme: AppThemePalette,
        isStreaming: Bool = false
    ) -> AttributedString {
        let normalizedInput = isStreaming ? MarkdownParser.stabilizeStreamingInline(text) : text
        let weightTag = weight == .bold ? "b" : "r"
        let cacheKey = "\(theme.backgroundHex)-\(theme.accentHex)-\(Int(fontSize * 10))-\(weightTag)-\(normalizedInput)" as NSString
        if !isStreaming, normalizedInput.utf8.count < 4000, let cached = attrCache.object(forKey: cacheKey) {
            return cached.attr
        }

        let prepared = MarkdownParser.enrichAutoLinksAndSpaces(normalizedInput)
        guard var attr = try? AttributedString(
            markdown: prepared,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            var fallback = AttributedString(normalizedInput)
            fallback.font = .system(size: fontSize, weight: weight)
            fallback.foregroundColor = UIColor(theme.primaryText)
            if !isStreaming, normalizedInput.utf8.count < 4000 {
                attrCache.setObject(AttrBox(fallback), forKey: cacheKey)
            }
            return fallback
        }

        let codeBg = UIColor(theme.elevatedBackground)
        let codeFg = UIColor(theme.primaryText)
        let linkFg = UIColor(theme.accent)
        let primaryFg = UIColor(theme.primaryText)

        for run in attr.runs {
            let range = run.range
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    attr[range].font = .system(size: max(12.5, fontSize - 1.5), weight: .medium, design: .monospaced)
                    attr[range].backgroundColor = codeBg
                    attr[range].foregroundColor = codeFg
                } else if intent.contains(.stronglyEmphasized) {
                    attr[range].font = .system(size: fontSize, weight: .bold)
                    attr[range].foregroundColor = primaryFg
                } else if intent.contains(.emphasized) {
                    attr[range].font = .system(size: fontSize, weight: weight).italic()
                    attr[range].foregroundColor = primaryFg
                } else {
                    attr[range].font = .system(size: fontSize, weight: weight)
                    attr[range].foregroundColor = primaryFg
                }
            } else {
                attr[range].font = .system(size: fontSize, weight: weight)
                attr[range].foregroundColor = primaryFg
            }
            if run.link != nil {
                attr[range].foregroundColor = linkFg
                attr[range].underlineStyle = .single
            }
        }

        if !isStreaming, normalizedInput.utf8.count < 4000 {
            attrCache.setObject(AttrBox(attr), forKey: cacheKey)
        }
        return attr
    }
}

struct MarkdownDocumentView: View {
    let content: String
    let theme: AppThemePalette
    var contentWidth: CGFloat? = nil
    var isStreaming: Bool = false

    var body: some View {
        let blocks = MarkdownRenderCache.shared.blocks(for: content, isStreaming: isStreaming)
        VStack(alignment: .leading, spacing: 8) {
            if isStreaming {
                ForEach(blocks) { block in
                    MarkdownBlockItemView(
                        block: block,
                        theme: theme,
                        contentWidth: contentWidth,
                        isStreaming: block.id == blocks.last?.id
                    )
                }
            } else {
                ForEach(MarkdownRenderSegment.make(from: blocks)) { segment in
                    if segment.isMergedText {
                        MarkdownMergedTextView(blocks: segment.blocks, theme: theme)
                    } else if let block = segment.blocks.first {
                        MarkdownBlockItemView(
                            block: block,
                            theme: theme,
                            contentWidth: contentWidth,
                            isStreaming: false
                        )
                    }
                }
            }
        }
        .tint(theme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension MarkdownBlock {
    var isMergeableText: Bool {
        switch self {
        case .paragraph, .list:
            return true
        case .heading(_, let level, _):
            return level >= 2
        default:
            return false
        }
    }
}

struct MarkdownRenderSegment: Identifiable {
    let id: Int
    let blocks: [MarkdownBlock]
    let isMergedText: Bool

    static func make(from blocks: [MarkdownBlock]) -> [MarkdownRenderSegment] {
        var result: [MarkdownRenderSegment] = []
        var buffer: [MarkdownBlock] = []

        func flush() {
            guard let first = buffer.first else { return }
            result.append(MarkdownRenderSegment(id: first.id, blocks: buffer, isMergedText: true))
            buffer.removeAll()
        }

        for block in blocks {
            if block.isMergeableText {
                buffer.append(block)
            } else {
                flush()
                result.append(MarkdownRenderSegment(id: block.id, blocks: [block], isMergedText: false))
            }
        }
        flush()
        return result
    }
}

struct MarkdownMergedTextView: View {
    let blocks: [MarkdownBlock]
    let theme: AppThemePalette

    var body: some View {
        SelectableRichTextView(
            attributedText: RichTextFormatter.makeDocumentNSAttributedString(blocks: blocks, theme: theme),
            theme: theme
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlockItemView: View, Equatable {
    let block: MarkdownBlock
    let theme: AppThemePalette
    let contentWidth: CGFloat?
    let isStreaming: Bool

    static func == (lhs: MarkdownBlockItemView, rhs: MarkdownBlockItemView) -> Bool {
        lhs.block == rhs.block &&
        lhs.theme == rhs.theme &&
        lhs.contentWidth == rhs.contentWidth &&
        lhs.isStreaming == rhs.isStreaming
    }

    var body: some View {
        switch block {
        case .heading(_, let level, let text):
            headingView(level: level, text: text)

        case .paragraph(_, let text):
            MarkdownInlineText(text: text, fontSize: 15, weight: .regular, theme: theme, isStreaming: isStreaming)
                .lineSpacing(3.5)

        case .list(_, let items):
            let minIndent = items.map(\.indent).min() ?? 0
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items) { item in
                    listItemView(item, baseIndent: minIndent)
                }
            }
            .padding(.vertical, 1)

        case .blockquote(_, let text):
            MarkdownInlineText(text: text, fontSize: 14, weight: .regular, theme: theme, isSecondary: true, isStreaming: isStreaming)
                .lineSpacing(3.5)
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.elevatedBackground.opacity(0.6))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.accent.opacity(0.8))
                        .frame(width: 3.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        case .codeBlock(_, let language, let code):
            CodeBlockCard(
                language: language,
                code: code,
                theme: theme,
                cardWidth: contentWidth,
                isStreaming: isStreaming
            )

        case .table(_, let headers, let alignments, let rows):
            MarkdownTableView(headers: headers, alignments: alignments, rows: rows, theme: theme, tableMaxWidth: contentWidth)

        case .divider:
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        let size: CGFloat = {
            switch level {
            case 1: return 19.0
            case 2: return 17.0
            case 3: return 15.8
            default: return 15.0
            }
        }()

        VStack(alignment: .leading, spacing: 4) {
            MarkdownInlineText(text: text, fontSize: size, weight: .bold, theme: theme, isStreaming: isStreaming)
                .lineSpacing(2.5)

            if level == 1 {
                Rectangle()
                    .fill(theme.border.opacity(0.6))
                    .frame(height: 1)
            }
        }
        .padding(.top, level <= 2 ? 4 : 2)
    }

    @ViewBuilder
    private func listItemView(_ item: MarkdownListItem, baseIndent: Int) -> some View {
        let normalizedIndent = max(0, min(item.indent - baseIndent, 4))
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch item.marker {
            case .bullet:
                Text(normalizedIndent == 0 ? "•" : (normalizedIndent == 1 ? "◦" : "▪"))
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundColor(theme.primaryText)
                    .frame(width: 12, alignment: .center)

            case .ordered(let num):
                Text(num)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.primaryText)
                    .frame(minWidth: 16, alignment: .trailing)

            case .task(let checked):
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(checked ? theme.accent : theme.secondaryText)
                    .frame(width: 15, alignment: .center)
            }

            MarkdownInlineText(text: item.text, fontSize: 15, weight: .regular, theme: theme, isStreaming: isStreaming)
                .lineSpacing(3.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(normalizedIndent) * 14)
    }
}

final class StreamingRevealTracker {
    struct Segment {
        let start: Int
        let date: Date
    }

    static let fadeDuration: TimeInterval = 0.45

    private(set) var segments: [Segment] = []
    private var lastLength: Int = 0

    func register(length: Int, now: Date, isStreaming: Bool) -> [Segment] {
        if length < lastLength {
            segments.removeAll { $0.start >= length }
        } else if length > lastLength && isStreaming {
            segments.append(Segment(start: lastLength, date: now))
        }
        lastLength = length
        segments.removeAll { now.timeIntervalSince($0.date) >= Self.fadeDuration }
        return segments
    }

    struct RevealRun {
        let range: Range<AttributedString.Index>
        let color: Color
        let date: Date
    }

    static func opacity(since start: Date, at date: Date) -> Double {
        let progress = min(1, max(0, date.timeIntervalSince(start) / fadeDuration))
        let eased = 1 - pow(1 - progress, 3)
        return 0.06 + 0.94 * eased
    }

    static func revealRuns(
        in attr: AttributedString,
        segments: [Segment],
        baseColor: Color,
        linkColor: Color
    ) -> [RevealRun] {
        guard !segments.isEmpty else { return [] }
        let characters = attr.characters
        let total = characters.count
        var cursor = characters.startIndex
        var cursorOffset = 0
        var result: [RevealRun] = []
        for (offset, segment) in segments.enumerated() {
            let start = min(segment.start, total)
            let end = offset + 1 < segments.count ? min(segments[offset + 1].start, total) : total
            guard end > start, start >= cursorOffset else { continue }
            let lower = characters.index(cursor, offsetBy: start - cursorOffset)
            let upper = characters.index(lower, offsetBy: end - start)
            cursor = upper
            cursorOffset = end
            for run in attr[lower..<upper].runs {
                let color: Color = run.link != nil ? linkColor : baseColor
                result.append(RevealRun(range: run.range, color: color, date: segment.date))
            }
        }
        return result
    }

    static func render(_ attr: AttributedString, runs: [RevealRun], at date: Date) -> AttributedString {
        var result = attr
        for run in runs {
            let alpha = opacity(since: run.date, at: date)
            guard alpha < 0.995 else { continue }
            result[run.range].foregroundColor = run.color.opacity(alpha)
        }
        return result
    }
}

struct StreamingRevealSchedule: TimelineSchedule {
    let end: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(current: startDate, end: end)
    }

    struct Entries: Sequence, IteratorProtocol {
        var current: Date
        let end: Date
        var finished = false

        mutating func next() -> Date? {
            guard !finished else { return nil }
            if current >= end {
                finished = true
                return end
            }
            let value = current
            current = current.addingTimeInterval(1.0 / 60.0)
            return value
        }
    }
}

struct MarkdownInlineText: View {
    let text: String
    var fontSize: CGFloat = 15
    var weight: Font.Weight = .regular
    let theme: AppThemePalette
    var isSecondary: Bool = false
    var isStreaming: Bool = false

    @State private var revealTracker = StreamingRevealTracker()

    var body: some View {
        let attr = MarkdownRenderCache.shared.attributedString(
            for: text,
            fontSize: fontSize,
            weight: weight,
            theme: theme,
            isStreaming: isStreaming
        )
        let baseColor: Color = isSecondary ? theme.secondaryText : theme.primaryText
        let activeSegments = revealTracker.register(length: attr.characters.count, now: Date(), isStreaming: isStreaming)
        if isStreaming {
            if let lastSegment = activeSegments.last {
                let runs = StreamingRevealTracker.revealRuns(
                    in: attr,
                    segments: activeSegments,
                    baseColor: baseColor,
                    linkColor: theme.accent
                )
                TimelineView(StreamingRevealSchedule(end: lastSegment.date.addingTimeInterval(StreamingRevealTracker.fadeDuration))) { context in
                    styledText(StreamingRevealTracker.render(attr, runs: runs, at: context.date), baseColor: baseColor)
                }
                .id(lastSegment.date)
            } else {
                styledText(attr, baseColor: baseColor)
            }
        } else {
            let nsAttr = RichTextFormatter.makeNSAttributedString(
                from: attr,
                fontSize: fontSize,
                weight: weight,
                baseColor: baseColor,
                lineSpacing: 3.5
            )
            SelectableRichTextView(attributedText: nsAttr, theme: theme)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func styledText(_ value: AttributedString, baseColor: Color) -> some View {
        Text(value)
            .font(.system(size: fontSize, weight: weight))
            .foregroundColor(baseColor)
            .tint(theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownTableView: View {
    let headers: [String]
    let alignments: [HorizontalAlignment]
    let rows: [[String]]
    let theme: AppThemePalette
    var tableMaxWidth: CGFloat? = nil

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
                calculated = 44
            } else if maxUnits <= 8 {
                calculated = max(64, CGFloat(maxUnits) * 10.0 + 20)
            } else if maxUnits <= 18 {
                calculated = min(150, max(88, CGFloat(maxUnits) * 8.5 + 20))
            } else {
                calculated = min(220, max(145, CGFloat(maxUnits) * 6.2 + 24))
            }
            widths.append(calculated)
        }

        let availableWidth = tableMaxWidth ?? max(240, UIScreen.main.bounds.width - 78)
        let total = widths.reduce(0, +)
        if total > 0 && total < availableWidth {
            let scale = availableWidth / total
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
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            )
        }
        .frame(width: tableMaxWidth, alignment: .leading)
    }

    @ViewBuilder
    private func tableRowView(
        cells: [String],
        widths: [CGFloat],
        isHeader: Bool,
        isAlternate: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { col in
                let cellText = col < cells.count ? cells[col] : ""
                let width = col < widths.count ? widths[col] : 100
                let align = col < alignments.count ? alignments[col] : .leading

                cellContent(text: cellText, isHeader: isHeader, alignment: align)
                    .padding(.horizontal, 10)
                    .padding(.vertical, isHeader ? 9 : 8)
                    .frame(width: width, alignment: frameAlignment(for: align))
                    .overlay(alignment: .trailing) {
                        if col < columnCount - 1 {
                            Rectangle()
                                .fill(theme.border.opacity(0.75))
                                .frame(width: 1)
                        }
                    }
            }
        }
        .background(
            isHeader
                ? theme.elevatedBackground
                : (isAlternate ? theme.elevatedBackground.opacity(0.28) : theme.cardBackground)
        )
    }

    @ViewBuilder
    private func cellContent(text: String, isHeader: Bool, alignment: HorizontalAlignment) -> some View {
        let fontSize: CGFloat = isHeader ? 13 : 13.5
        Text(MarkdownRenderCache.shared.attributedString(for: text, fontSize: fontSize, theme: theme))
            .font(.system(size: fontSize, weight: isHeader ? .semibold : .regular))
            .foregroundColor(theme.primaryText)
            .tint(theme.accent)
            .multilineTextAlignment(textAlignment(for: alignment))
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
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

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

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

            if isHorizontalRule(trimmed) {
                flushParagraph()
                blocks.append(.divider(id: nextId))
                nextId += 1
                i += 1
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(id: nextId, level: heading.level, text: heading.text))
                nextId += 1
                i += 1
                continue
            }

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
                    } else if (nextLine.hasPrefix("  ") || nextLine.hasPrefix("\t")),
                              !nextTrimmed.hasPrefix("#"),
                              !nextTrimmed.hasPrefix("```"),
                              !nextTrimmed.hasPrefix(">"),
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

            paragraphBuffer.append(line)
            i += 1
        }

        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
        guard trimmed.first == "#" else { return nil }
        var level = 0
        for ch in trimmed {
            if ch == "#" {
                level += 1
            } else {
                break
            }
        }
        guard level >= 1 && level <= 6 else { return nil }
        let remainder = trimmed.dropFirst(level)
        guard let first = remainder.first,
              first == " " || first == "\t" || (first.unicodeScalars.first?.value ?? 0) > 127 else {
            return nil
        }
        var cleaned = remainder.trimmingCharacters(in: .whitespaces)
        while cleaned.hasSuffix("#") {
            cleaned.removeLast()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return (level, cleaned)
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else { return false }
        guard trimmed.count >= 3 else { return false }
        var count = 0
        for ch in trimmed {
            if ch == first {
                count += 1
            } else if ch != " " {
                return false
            }
        }
        return count >= 3
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
        guard let first = trimmed.first else { return nil }

        if first == "-" || first == "*" || first == "+" || first == "•" {
            let afterBullet = trimmed.dropFirst()
            guard afterBullet.first == " " || afterBullet.first == "\t" else { return nil }
            let body = afterBullet.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("[ ] ") || body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
                let checked = body.hasPrefix("[x] ") || body.hasPrefix("[X] ")
                let taskText = String(body.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                return MarkdownListItem(id: id, indent: indent, marker: .task(checked), text: taskText)
            }
            return MarkdownListItem(id: id, indent: indent, marker: .bullet, text: body)
        }

        if first.isNumber {
            var idx = trimmed.startIndex
            while idx < trimmed.endIndex, trimmed[idx].isNumber {
                idx = trimmed.index(after: idx)
            }
            guard idx < trimmed.endIndex, (trimmed[idx] == "." || trimmed[idx] == ")") else {
                return nil
            }
            let afterDot = trimmed.index(after: idx)
            guard afterDot < trimmed.endIndex, (trimmed[afterDot] == " " || trimmed[afterDot] == "\t") else {
                return nil
            }
            let markerStr = String(trimmed[..<afterDot])
            let body = String(trimmed[afterDot...]).trimmingCharacters(in: .whitespaces)
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
            guard !c.isEmpty else { return nil }
            var slice = Substring(c)
            let hasLeadingColon = slice.first == ":"
            if hasLeadingColon { slice = slice.dropFirst() }
            let hasTrailingColon = slice.last == ":"
            if hasTrailingColon { slice = slice.dropLast() }
            guard !slice.isEmpty && slice.allSatisfy({ $0 == "-" }) else {
                return nil
            }
            if hasLeadingColon && hasTrailingColon {
                alignments.append(.center)
            } else if hasTrailingColon {
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

    static func stabilizeStreamingInline(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var lines = input.components(separatedBy: "\n")
        guard let lastIdx = lines.indices.last else { return input }
        var lastLine = lines[lastIdx]

        if lastLine.hasSuffix("**") {
            let withoutTrailing = String(lastLine.dropLast(2))
            let previousPairs = withoutTrailing.components(separatedBy: "**").count - 1
            if previousPairs % 2 == 0 {
                lastLine = withoutTrailing
            }
        } else if lastLine.hasSuffix("*") && !lastLine.hasSuffix("**") {
            lastLine.removeLast()
        }

        let boldCount = lastLine.components(separatedBy: "**").count - 1
        if boldCount % 2 == 1 {
            lastLine += "**"
        }

        let backtickCount = lastLine.filter { $0 == "`" }.count
        if backtickCount % 2 == 1 {
            if lastLine.hasSuffix("`") {
                lastLine.removeLast()
            } else {
                lastLine += "`"
            }
        }

        lines[lastIdx] = lastLine
        return lines.joined(separator: "\n")
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

        if joined.contains("github.com/") && !joined.contains("](") && !joined.contains("`") {
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
        if s.contains("](") {
            s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        }
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

enum RichTextFormatter {
    static func makeDocumentNSAttributedString(
        blocks: [MarkdownBlock],
        theme: AppThemePalette
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let primary = theme.primaryText

        for (index, block) in blocks.enumerated() {
            let isLastBlock = index == blocks.count - 1
            var blockSpacing: CGFloat = 0
            if !isLastBlock {
                blockSpacing = 8
                if case .heading(_, let nextLevel, _) = blocks[index + 1] {
                    blockSpacing += nextLevel <= 2 ? 4 : 2
                }
            }

            switch block {
            case .paragraph(_, let text):
                let body = inlineBody(text: text, fontSize: 15, weight: .regular, theme: theme)
                appendPiece(
                    to: result,
                    prefix: nil,
                    body: body,
                    fontSize: 15,
                    weight: .regular,
                    color: primary,
                    firstLineIndent: 0,
                    headIndent: 0,
                    tabLocation: nil,
                    lineSpacing: 3.5,
                    spacingAfter: blockSpacing,
                    appendNewline: !isLastBlock
                )

            case .heading(_, let level, let text):
                let size: CGFloat
                switch level {
                case 1: size = 19.0
                case 2: size = 17.0
                case 3: size = 15.8
                default: size = 15.0
                }
                let body = inlineBody(text: text, fontSize: size, weight: .bold, theme: theme)
                appendPiece(
                    to: result,
                    prefix: nil,
                    body: body,
                    fontSize: size,
                    weight: .bold,
                    color: primary,
                    firstLineIndent: 0,
                    headIndent: 0,
                    tabLocation: nil,
                    lineSpacing: 2.5,
                    spacingAfter: blockSpacing,
                    appendNewline: !isLastBlock
                )

            case .list(_, let items):
                let minIndent = items.map(\.indent).min() ?? 0
                for (itemIndex, item) in items.enumerated() {
                    let isLastItem = itemIndex == items.count - 1
                    let normalized = max(0, min(item.indent - minIndent, 4))
                    var markerColor = UIColor(primary)
                    let markerText: String
                    switch item.marker {
                    case .bullet:
                        markerText = normalized == 0 ? "•" : (normalized == 1 ? "◦" : "▪")
                    case .ordered(let number):
                        markerText = number
                    case .task(let checked):
                        markerText = checked ? "☑" : "☐"
                        if checked {
                            markerColor = UIColor(theme.accent)
                        }
                    }
                    let indentPoints = CGFloat(normalized) * 14
                    let markerWidth: CGFloat = 22
                    let marker = NSAttributedString(
                        string: markerText + "\t",
                        attributes: [
                            .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
                            .foregroundColor: markerColor
                        ]
                    )
                    let body = inlineBody(text: item.text, fontSize: 15, weight: .regular, theme: theme)
                    appendPiece(
                        to: result,
                        prefix: marker,
                        body: body,
                        fontSize: 15,
                        weight: .regular,
                        color: primary,
                        firstLineIndent: indentPoints,
                        headIndent: indentPoints + markerWidth,
                        tabLocation: indentPoints + markerWidth,
                        lineSpacing: 3.5,
                        spacingAfter: isLastItem ? blockSpacing : 5,
                        appendNewline: !(isLastBlock && isLastItem)
                    )
                }

            default:
                continue
            }
        }

        while result.length > 0, result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        return result
    }

    private static func inlineBody(
        text: String,
        fontSize: CGFloat,
        weight: Font.Weight,
        theme: AppThemePalette
    ) -> NSAttributedString {
        let attr = MarkdownRenderCache.shared.attributedString(
            for: text,
            fontSize: fontSize,
            weight: weight,
            theme: theme
        )
        return makeNSAttributedString(
            from: attr,
            fontSize: fontSize,
            weight: weight,
            baseColor: theme.primaryText
        )
    }

    private static func appendPiece(
        to result: NSMutableAttributedString,
        prefix: NSAttributedString?,
        body: NSAttributedString,
        fontSize: CGFloat,
        weight: UIFont.Weight,
        color: Color,
        firstLineIndent: CGFloat,
        headIndent: CGFloat,
        tabLocation: CGFloat?,
        lineSpacing: CGFloat,
        spacingAfter: CGFloat,
        appendNewline: Bool
    ) {
        guard body.length > 0 || prefix != nil else { return }

        let piece = NSMutableAttributedString()
        if let prefix = prefix {
            piece.append(prefix)
        }
        piece.append(body)
        if appendNewline {
            piece.append(NSAttributedString(
                string: "\n",
                attributes: [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
                    .foregroundColor: UIColor(color)
                ]
            ))
        }

        let nsString = piece.string as NSString
        var location = 0
        var isFirstParagraph = true
        while location < piece.length {
            let paragraphRange = nsString.paragraphRange(for: NSRange(location: location, length: 0))
            let isLastParagraph = NSMaxRange(paragraphRange) >= piece.length
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.firstLineHeadIndent = isFirstParagraph ? firstLineIndent : headIndent
            style.headIndent = headIndent
            style.paragraphSpacing = isLastParagraph ? spacingAfter : 0
            if let tabLocation = tabLocation {
                style.tabStops = [NSTextTab(textAlignment: .left, location: tabLocation, options: [:])]
            }
            piece.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
            location = NSMaxRange(paragraphRange)
            isFirstParagraph = false
        }

        result.append(piece)
    }

    static func makeNSAttributedString(
        from attr: AttributedString,
        fontSize: CGFloat,
        weight: Font.Weight,
        baseColor: Color,
        lineSpacing: CGFloat = 3.5
    ) -> NSAttributedString {
        let mutable: NSMutableAttributedString
        if let converted = try? NSAttributedString(attr, including: \.uiKit) {
            mutable = NSMutableAttributedString(attributedString: converted)
        } else {
            mutable = NSMutableAttributedString(string: String(attr.characters))
        }

        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else {
            return NSAttributedString()
        }

        let uiWeight: UIFont.Weight = (weight == .bold) ? .bold : .regular
        let defaultFont = UIFont.systemFont(ofSize: fontSize, weight: uiWeight)
        let defaultColor = UIColor(baseColor)

        mutable.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.font, value: defaultFont, range: range)
            }
        }

        mutable.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.foregroundColor, value: defaultColor, range: range)
            }
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        mutable.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)

        return mutable
    }

    static func makePlainTextNSAttributedString(
        text: String,
        fontSize: CGFloat,
        weight: UIFont.Weight = .regular,
        color: UIColor,
        lineSpacing: CGFloat = 3.5
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }
}

struct SelectableRichTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let theme: AppThemePalette

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.tintColor = UIColor(theme.accent)
        textView.adjustsFontForContentSizeCategory = true
        textView.delegate = context.coordinator
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.attributedText = attributedText
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.attributedText.string != attributedText.string || !uiView.attributedText.isEqual(to: attributedText) {
            uiView.attributedText = attributedText
        }
        let accentColor = UIColor(theme.accent)
        if uiView.tintColor != accentColor {
            uiView.tintColor = accentColor
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let targetWidth = proposal.width ?? UIScreen.main.bounds.width
        let fit = uiView.sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: targetWidth, height: ceil(fit.height))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            UIApplication.shared.open(URL)
            return false
        }
    }
}
