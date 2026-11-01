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

    var diagnosticType: String {
        switch self {
        case .heading: return "heading"
        case .paragraph: return "paragraph"
        case .list: return "list"
        case .blockquote: return "blockquote"
        case .codeBlock: return "code"
        case .table: return "table"
        case .divider: return "divider"
        }
    }

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

    private struct StreamingCheckpoint {
        let stablePrefix: String
        let stableUTF8Count: Int
        let stableBlocks: [MarkdownBlock]
        let nextBlockId: Int
    }

    private var streamingCheckpoint: StreamingCheckpoint?
    private var lastStreamingFullInput: String = ""
    private var lastStreamingFullBlocks: [MarkdownBlock] = []

    final class BlockBox {
        let source: String
        let blocks: [MarkdownBlock]
        init(source: String, blocks: [MarkdownBlock]) {
            self.source = source
            self.blocks = blocks
        }
    }

    final class AttrBox {
        let attr: AttributedString
        let urls: [URL]
        init(attr: AttributedString, urls: [URL]) {
            self.attr = attr
            self.urls = urls
        }
    }

    private init() {
        blockCache.countLimit = 140
        attrCache.countLimit = 800
    }

    func blocks(for content: String, isStreaming: Bool = false) -> [MarkdownBlock] {
        if isStreaming {
            return streamingBlocks(for: content)
        }
        if content.utf8.count > 32_000 {
            return MarkdownParser.parse(content)
        }
        let key = "\(content.utf8.count)|\(content.hashValue)" as NSString
        if let cached = blockCache.object(forKey: key), cached.source == content {
            return cached.blocks
        }
        let parsed = MarkdownParser.parse(content)
        blockCache.setObject(BlockBox(source: content, blocks: parsed), forKey: key)
        return parsed
    }

    private func streamingBlocks(for raw: String) -> [MarkdownBlock] {
        let normalized = raw.contains("\r") ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw
        if normalized == lastStreamingFullInput {
            return lastStreamingFullBlocks
        }

        if let cp = streamingCheckpoint,
           normalized.utf8.count >= cp.stableUTF8Count,
           normalized.hasPrefix(cp.stablePrefix),
           let tailStart = normalized.utf8.index(normalized.utf8.startIndex, offsetBy: cp.stableUTF8Count).samePosition(in: normalized) {
            let tail = String(normalized[tailStart...])
            let tailResult = MarkdownParser.parseIncremental(tail, startingId: cp.nextBlockId)
            let combined = cp.stableBlocks + tailResult.blocks
            if let localSafeUTF8 = tailResult.safePrefixUTF8Count, localSafeUTF8 > 0,
               let newSafeEnd = tail.utf8.index(tail.utf8.startIndex, offsetBy: localSafeUTF8).samePosition(in: tail) {
                let newPrefix = cp.stablePrefix + String(tail[..<newSafeEnd])
                streamingCheckpoint = StreamingCheckpoint(
                    stablePrefix: newPrefix,
                    stableUTF8Count: newPrefix.utf8.count,
                    stableBlocks: cp.stableBlocks + tailResult.safeBlocks,
                    nextBlockId: tailResult.safeNextBlockId
                )
            }
            lastStreamingFullInput = normalized
            lastStreamingFullBlocks = combined
            return combined
        }

        let fullResult = MarkdownParser.parseIncremental(normalized, startingId: 1)
        if let safeUTF8 = fullResult.safePrefixUTF8Count, safeUTF8 > 0,
           let safeEnd = normalized.utf8.index(normalized.utf8.startIndex, offsetBy: safeUTF8).samePosition(in: normalized) {
            let prefix = String(normalized[..<safeEnd])
            streamingCheckpoint = StreamingCheckpoint(
                stablePrefix: prefix,
                stableUTF8Count: prefix.utf8.count,
                stableBlocks: fullResult.safeBlocks,
                nextBlockId: fullResult.safeNextBlockId
            )
        } else {
            streamingCheckpoint = nil
        }
        lastStreamingFullInput = normalized
        lastStreamingFullBlocks = fullResult.blocks
        return fullResult.blocks
    }

    func richInline(
        for normalizedInput: String,
        fontSize: CGFloat,
        theme: AppThemePalette
    ) -> (attr: AttributedString, urls: [URL]) {
        let cacheKey = "\(theme.backgroundHex)-\(theme.accentHex)-\(Int(fontSize * 10))-\(normalizedInput)" as NSString
        if normalizedInput.utf8.count < 4000, let cached = attrCache.object(forKey: cacheKey) {
            return (cached.attr, cached.urls)
        }

        let prepared = MarkdownParser.enrichAutoLinksAndSpaces(normalizedInput)
        guard var attr = try? AttributedString(
            markdown: prepared,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            let fallback = AttributedString(normalizedInput)
            if normalizedInput.utf8.count < 4000 {
                attrCache.setObject(AttrBox(attr: fallback, urls: []), forKey: cacheKey)
            }
            return (fallback, [])
        }

        let codeBg = UIColor(theme.elevatedBackground)
        let codeFg = UIColor(theme.primaryText)
        let linkFg = UIColor(theme.accent)
        var seenURLs = Set<String>()
        var extractedURLs: [URL] = []

        for run in attr.runs {
            let range = run.range
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attr[range].font = .system(size: max(12.5, fontSize - 1.5), weight: .medium, design: .monospaced)
                attr[range].backgroundColor = codeBg
                attr[range].foregroundColor = codeFg
            }
            if let url = run.link {
                attr[range].foregroundColor = linkFg
                attr[range].underlineStyle = .single
                if seenURLs.insert(url.absoluteString).inserted {
                    extractedURLs.append(url)
                }
            }
        }

        if normalizedInput.utf8.count < 4000 {
            attrCache.setObject(AttrBox(attr: attr, urls: extractedURLs), forKey: cacheKey)
        }
        return (attr, extractedURLs)
    }

    func attributedString(
        for text: String,
        fontSize: CGFloat,
        theme: AppThemePalette,
        isStreaming: Bool = false
    ) -> AttributedString {
        let normalizedInput = isStreaming ? MarkdownParser.stabilizeStreamingInline(text) : text
        if !MarkdownParser.mayNeedRichInlineParsing(normalizedInput) {
            return AttributedString(normalizedInput)
        }
        return richInline(for: normalizedInput, fontSize: fontSize, theme: theme).attr
    }
}

private struct MarkdownLinkCopyContextMenu: ViewModifier {
    let urls: [URL]

    func body(content: Content) -> some View {
        if urls.isEmpty {
            content
        } else {
            content.contextMenu {
                ForEach(urls, id: \.absoluteString) { url in
                    Button {
                        UIPasteboard.general.url = url
                    } label: {
                        Label(copyTitle(for: url), systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }

    private func copyTitle(for url: URL) -> String {
        let host = url.host ?? url.absoluteString
        let path = url.path == "/" ? "" : url.path
        return "复制 \(String((host + path).prefix(42)))"
    }
}

struct MarkdownDocumentView: View {
    let content: String
    let theme: AppThemePalette
    var contentWidth: CGFloat? = nil
    var isStreaming: Bool = false
    var diagnosticIDPrefix: String? = nil

    var body: some View {
        let blocks = MarkdownRenderCache.shared.blocks(for: content, isStreaming: isStreaming)
        let lastBlockId = blocks.last?.id
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                MarkdownBlockItemView(
                    block: block,
                    theme: theme,
                    contentWidth: contentWidth,
                    isStreaming: isStreaming && (block.id == lastBlockId)
                )
                .equatable()
                .modifier(ChatLayoutProbe(identifier: diagnosticIDPrefix.map { "markdownBlock|\($0)|\(block.id)|\(block.diagnosticType)" }))
            }
            .modifier(ChatLayoutProbe(identifier: diagnosticIDPrefix.map { "markdownBlocksGroup|\($0)" }))
        }
        .modifier(ChatLayoutProbe(identifier: diagnosticIDPrefix.map { "markdownStack|\($0)" }))
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
                .equatable()
                .lineSpacing(3.5)

        case .list(_, let items):
            let minIndent = items.map(\.indent).min() ?? 0
            VStack(alignment: .leading, spacing: 5) {
                ForEach(items) { item in
                    listItemView(item, baseIndent: minIndent, isLastItem: isStreaming && item.id == items.last?.id)
                }
            }
            .padding(.vertical, 1)

        case .blockquote(_, let text):
            MarkdownInlineText(text: text, fontSize: 14, weight: .regular, theme: theme, isSecondary: true, isStreaming: isStreaming)
                .equatable()
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
                .equatable()
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
    private func listItemView(_ item: MarkdownListItem, baseIndent: Int, isLastItem: Bool) -> some View {
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

            MarkdownInlineText(text: item.text, fontSize: 15, weight: .regular, theme: theme, isStreaming: isLastItem)
                .equatable()
                .lineSpacing(3.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(normalizedIndent) * 14)
    }
}

struct MarkdownInlineText: View, Equatable {
    let text: String
    var fontSize: CGFloat = 15
    var weight: Font.Weight = .regular
    let theme: AppThemePalette
    var isSecondary: Bool = false
    var isStreaming: Bool = false

    static func == (lhs: MarkdownInlineText, rhs: MarkdownInlineText) -> Bool {
        lhs.text == rhs.text &&
        lhs.fontSize == rhs.fontSize &&
        lhs.weight == rhs.weight &&
        lhs.theme == rhs.theme &&
        lhs.isSecondary == rhs.isSecondary &&
        lhs.isStreaming == rhs.isStreaming
    }

    var body: some View {
        let normalizedInput = isStreaming ? MarkdownParser.stabilizeStreamingInline(text) : text
        let baseColor: Color = isSecondary ? theme.secondaryText : theme.primaryText

        if !MarkdownParser.mayNeedRichInlineParsing(normalizedInput) {
            // 纯文本快速通道：跳过 CommonMark 解析器与 AttributedString 转换，进入长对话速度提升数倍
            Text(normalizedInput)
                .font(.system(size: fontSize, weight: weight))
                .foregroundColor(baseColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let rich = MarkdownRenderCache.shared.richInline(
                for: normalizedInput,
                fontSize: fontSize,
                theme: theme
            )
            Text(rich.attr)
                .font(.system(size: fontSize, weight: weight))
                .foregroundColor(baseColor)
                .tint(theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(MarkdownLinkCopyContextMenu(urls: rich.urls))
        }
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
        .frame(maxWidth: tableMaxWidth ?? .infinity, alignment: .leading)
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
        if !MarkdownParser.mayNeedRichInlineParsing(text) {
            Text(text)
                .font(.system(size: fontSize, weight: isHeader ? .semibold : .regular))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(textAlignment(for: alignment))
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let rich = MarkdownRenderCache.shared.richInline(for: text, fontSize: fontSize, theme: theme)
            Text(rich.attr)
                .font(.system(size: fontSize, weight: isHeader ? .semibold : .regular))
                .foregroundColor(theme.primaryText)
                .tint(theme.accent)
                .multilineTextAlignment(textAlignment(for: alignment))
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(MarkdownLinkCopyContextMenu(urls: rich.urls))
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
    struct IncrementalResult {
        let blocks: [MarkdownBlock]
        let safePrefixUTF8Count: Int?
        let safeBlocks: [MarkdownBlock]
        let safeNextBlockId: Int
    }

    /// 零分配 UTF-8 扫描：判断字符串是否可能包含任何 Markdown 内联标记或缩进/自动链接
    static func mayNeedRichInlineParsing(_ text: String) -> Bool {
        let utf8 = text.utf8
        guard let first = utf8.first else { return false }
        if first == 0x20 || first == 0x09 {
            return true
        }
        var prevWasNewline = false
        var hasSlash = false
        for byte in utf8 {
            if prevWasNewline && (byte == 0x20 || byte == 0x09) {
                return true
            }
            prevWasNewline = (byte == 0x0A)
            switch byte {
            case 0x2A, 0x5F, 0x60, 0x5B, 0x7E, 0x5C, 0x3C:
                // * _ ` [ ~ \ <
                return true
            case 0x2F:
                hasSlash = true
            default:
                break
            }
        }
        if hasSlash && (text.contains("http://") || text.contains("https://") || text.contains("github.com/")) {
            return true
        }
        return false
    }

    static func parse(_ raw: String) -> [MarkdownBlock] {
        let normalized = raw.contains("\r") ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw
        return parseIncremental(normalized, startingId: 1).blocks
    }

    static func parseIncremental(_ normalized: String, startingId: Int) -> IncrementalResult {
        let lines = normalized.components(separatedBy: "\n")
        var lineStartUTF8Offsets: [Int] = []
        lineStartUTF8Offsets.reserveCapacity(lines.count + 1)
        var runningOffset = 0
        for (idx, l) in lines.enumerated() {
            lineStartUTF8Offsets.append(runningOffset)
            runningOffset += l.utf8.count + (idx < lines.count - 1 ? 1 : 0)
        }
        lineStartUTF8Offsets.append(normalized.utf8.count)

        var blocks: [MarkdownBlock] = []
        var nextId = startingId

        var safePrefixUTF8Count: Int? = nil
        var safeBlocks: [MarkdownBlock] = []
        var safeNextBlockId = startingId

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

        func recordCheckpointIfHasRemaining(atLineIndex lineIdx: Int) {
            guard !blocks.isEmpty, lineIdx < lines.count else { return }
            safePrefixUTF8Count = lineStartUTF8Offsets[lineIdx]
            safeBlocks = blocks
            safeNextBlockId = nextId
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                while i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    i += 1
                }
                if i < lines.count {
                    recordCheckpointIfHasRemaining(atLineIndex: i)
                }
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let langRaw = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let lang = langRaw.isEmpty ? "code" : langRaw
                i += 1
                var codeLines: [String] = []
                var didCloseFence = false
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) {
                        didCloseFence = true
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(id: nextId, language: lang, code: codeLines.joined(separator: "\n")))
                nextId += 1
                if didCloseFence && i < lines.count {
                    recordCheckpointIfHasRemaining(atLineIndex: i)
                }
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
                if i < lines.count {
                    recordCheckpointIfHasRemaining(atLineIndex: i)
                }
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(id: nextId, level: heading.level, text: heading.text))
                nextId += 1
                i += 1
                if i < lines.count {
                    recordCheckpointIfHasRemaining(atLineIndex: i)
                }
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
        return IncrementalResult(
            blocks: blocks,
            safePrefixUTF8Count: safePrefixUTF8Count,
            safeBlocks: safeBlocks,
            safeNextBlockId: safeNextBlockId
        )
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

        let backtickCount = lastLine.filter { $0 == "`" }.count
        if backtickCount % 2 == 1 {
            if lastLine.hasSuffix("`") {
                lastLine.removeLast()
            } else {
                lastLine += "`"
            }
            lines[lastIdx] = lastLine
            return lines.joined(separator: "\n")
        }

        if let linkSplit = lastLine.range(of: "](", options: .backwards) {
            let afterParen = lastLine[linkSplit.upperBound...]
            if !afterParen.contains(")") && !afterParen.contains(" ") {
                let beforeLinkSplit = lastLine[..<linkSplit.lowerBound]
                if let openBracket = beforeLinkSplit.lastIndex(of: "[") {
                    let label = lastLine[lastLine.index(after: openBracket)..<linkSplit.lowerBound]
                    lastLine = String(lastLine[..<openBracket]) + label
                }
            }
        }

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
