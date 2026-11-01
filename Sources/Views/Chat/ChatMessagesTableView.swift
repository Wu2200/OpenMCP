import SwiftUI
import UIKit

private struct ChatCellLayoutInvalidatorKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var chatCellLayoutInvalidator: () -> Void {
        get { self[ChatCellLayoutInvalidatorKey.self] }
        set { self[ChatCellLayoutInvalidatorKey.self] = newValue }
    }
}

enum ChatListRowItem: Identifiable, Equatable {
    case turn(
        turn: MessageDisplayTurn,
        isActiveGenerating: Bool,
        isSelected: Bool,
        isGeneratingGlobal: Bool,
        statusText: String,
        thinkingStartTime: Date?,
        modelName: String
    )
    case generatingStatus(statusText: String, startDate: Date)
    case errorBanner(message: String, canRetry: Bool)

    var id: String {
        switch self {
        case .turn(let turn, _, _, _, _, _, _):
            return "turn_\(turn.id)"
        case .generatingStatus:
            return "__generating_status__"
        case .errorBanner:
            return "__error_banner__"
        }
    }

    var turnId: String? {
        if case .turn(let turn, _, _, _, _, _, _) = self {
            return turn.id
        }
        return nil
    }
}

@MainActor
final class ChatTableInspectorBridge {
    weak var controller: ChatMessagesTableViewController?

    func makeReport(conversationTitle: String, selectedTurnId: String?) -> String {
        guard let vc = controller else {
            return "OpenMCP 对话布局诊断报告\n尚未挂载对话表格控制器。"
        }
        return vc.buildDiagnosticsReport(selectedTurnId: selectedTurnId)
    }
}

@MainActor
private final class ChatRowHeightCache {
    static let shared = ChatRowHeightCache()

    private var storage: [String: CGFloat] = [:]

    private func makeKey(conversationId: String, rowId: String, widthBucket: Int) -> String {
        "\(conversationId)|\(rowId)|\(widthBucket)"
    }

    func height(conversationId: String, rowId: String, width: CGFloat) -> CGFloat? {
        storage[makeKey(conversationId: conversationId, rowId: rowId, widthBucket: Int(round(width)))]
    }

    func store(_ height: CGFloat, conversationId: String, rowId: String, width: CGFloat) {
        guard height > 16 else { return }
        if storage.count > 2_500 {
            storage.removeAll(keepingCapacity: true)
        }
        storage[makeKey(conversationId: conversationId, rowId: rowId, widthBucket: Int(round(width)))] = height
    }

    static func estimate(for item: ChatListRowItem, rowWidth: CGFloat) -> CGFloat {
        switch item {
        case .generatingStatus:
            return 54
        case .errorBanner(let msg, _):
            let lines = max(1, (msg.count + 24) / 25)
            return CGFloat(58 + lines * 18)
        case .turn(let turn, _, let isSelected, _, _, _, _):
            var total: CGFloat = 12 // 上下 cell 间距 (6 + 6)
            if isSelected {
                total += 34
            }
            if turn.role == .user {
                for att in turn.attachments {
                    total += (att.kind == .image) ? 176 : 82
                }
                let trimmed = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if ChatAttachment.shouldPackageAsLongText(trimmed) {
                        total += 82
                    } else {
                        let charsPerLine = max(14, Int((rowWidth - 64) / 15.5))
                        let explicitNewlines = trimmed.utf8.filter { $0 == 0x0A }.count
                        let wrappedLines = max(1, (trimmed.count + charsPerLine - 1) / charsPerLine + explicitNewlines)
                        total += CGFloat(wrappedLines) * 21.5 + 20
                    }
                }
                return max(50, total)
            } else {
                total += 22 // 卡片上下内边距
                if !turn.toolCalls.isEmpty {
                    total += 44
                }
                if !turn.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    total += 38
                }
                let text = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let charsPerLine = max(16, Int((rowWidth - 58) / 15.0))
                    let newlineCount = text.utf8.filter { $0 == 0x0A }.count
                    let approxLines = max(1, (text.count + charsPerLine - 1) / charsPerLine + newlineCount / 2)
                    total += min(1_800, CGFloat(approxLines) * 21.0 + 12)
                } else if turn.toolCalls.isEmpty && turn.reasoningContent.isEmpty {
                    total += 40
                }
                return max(54, total)
            }
        }
    }
}

private struct ChatRowHostedView: View {
    let item: ChatListRowItem
    let theme: AppThemePalette
    let rowAvailableWidth: CGFloat
    let streamingState: StreamingTurnState
    let onSelectToggle: (MessageDisplayTurn) -> Void
    let onEditBegin: (MessageDisplayTurn) -> Void
    let onEditEnd: (MessageDisplayTurn) -> Void
    let onDismissSelection: () -> Void
    let onEditSave: (MessageDisplayTurn, String) -> Void
    let onEditAndResend: (MessageDisplayTurn, String) -> Void
    let onRetryTurn: (MessageDisplayTurn) -> Void
    let onDeleteTurn: (MessageDisplayTurn) -> Void
    let onRetryLastFromError: () -> Void
    let onIntrinsicLayoutInvalidated: () -> Void

    var body: some View {
        Group {
            switch item {
            case .turn(
                let turn,
                let isActiveGenerating,
                let isSelected,
                let isGeneratingGlobal,
                let statusText,
                let thinkingStartTime,
                let modelName
            ):
                MessageBubbleView(
                    turn: turn,
                    theme: theme,
                    availableWidth: rowAvailableWidth,
                    modelName: modelName,
                    isGenerating: isGeneratingGlobal,
                    isActiveGeneratingTurn: isActiveGenerating,
                    statusText: statusText,
                    thinkingStartTime: thinkingStartTime,
                    streamingState: streamingState,
                    isSelected: isSelected,
                    onSelectToggle: { onSelectToggle(turn) },
                    onEditBegin: { onEditBegin(turn) },
                    onEditEnd: { onEditEnd(turn) },
                    onDismissSelection: onDismissSelection,
                    onEditSave: { text in onEditSave(turn, text) },
                    onEditAndResend: { text in onEditAndResend(turn, text) },
                    onRetry: { onRetryTurn(turn) },
                    onDelete: { onDeleteTurn(turn) }
                )

            case .generatingStatus(let statusText, let startDate):
                HStack(alignment: .top, spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(theme.accent.opacity(0.14))
                            .frame(width: 24, height: 24)
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.accent)
                    }
                    .padding(.top, 2)

                    ThinkingStatusView(
                        statusText: statusText,
                        startDate: startDate,
                        theme: theme,
                        isPaused: false
                    )
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(theme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    )

                    Spacer(minLength: 36)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onDismissSelection()
                        }
                }
                .frame(width: rowAvailableWidth, alignment: .leading)

            case .errorBanner(let message, let canRetry):
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 15))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundColor(theme.primaryText)

                        if canRetry {
                            Button(action: onRetryLastFromError) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise")
                                    Text("立即重试")
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(theme.accent)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer()
                }
                .padding(12)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.red.opacity(0.25), lineWidth: 1)
                )
                .padding(.leading, 30)
                .frame(width: rowAvailableWidth, alignment: .leading)
            }
        }
        .id(item.id)
        .environment(\.chatCellLayoutInvalidator, onIntrinsicLayoutInvalidated)
    }
}

private final class SizingHostingController<Content: View>: UIHostingController<Content> {
    var onIdealHeightChanged: ((CGFloat) -> Void)?
    private var lastReportedIdealHeight: CGFloat = 0

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        guard width > 24 else { return }
        let intrinsicH = view.intrinsicContentSize.height
        let idealHeight: CGFloat
        if intrinsicH > 1 {
            idealHeight = intrinsicH
        } else {
            idealHeight = sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        }
        if abs(idealHeight - lastReportedIdealHeight) > 0.5 {
            lastReportedIdealHeight = idealHeight
            onIdealHeightChanged?(idealHeight)
        }
    }

    func resetMeasuredHeight() {
        lastReportedIdealHeight = 0
    }
}

private final class ChatHostingTableViewCell: UITableViewCell {
    static let reuseIdentifier = "ChatHostingTableViewCell"

    private var hostingController: SizingHostingController<ChatRowHostedView>?
    var hostedView: UIView? { hostingController?.view }
    private(set) var currentRowId: String = ""
    var onCellIdealHeightChanged: ((ChatHostingTableViewCell, CGFloat) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hostingController?.resetMeasuredHeight()
    }

    func refreshHostedContentImmediately() {
        guard let hostedView = hostingController?.view else { return }
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
        hostedView.invalidateIntrinsicContentSize()
        hostedView.setNeedsUpdateConstraints()
        hostedView.setNeedsLayout()
        hostedView.layoutIfNeeded()
        hostedView.layer.setNeedsDisplay()
        hostedView.layer.displayIfNeeded()
    }

    func configure(
        rootView: ChatRowHostedView,
        rowId: String,
        parentController: UIViewController
    ) {
        currentRowId = rowId

        if let hc = hostingController {
            if hc.parent !== parentController {
                parentController.addChild(hc)
                hc.didMove(toParent: parentController)
            }
            hc.rootView = rootView
            hc.view.invalidateIntrinsicContentSize()
            hc.view.setNeedsLayout()
        } else {
            let hc = SizingHostingController(rootView: rootView)
            hc.sizingOptions = [.intrinsicContentSize]
            hc.view.backgroundColor = .clear
            hc.view.translatesAutoresizingMaskIntoConstraints = false

            parentController.addChild(hc)
            contentView.addSubview(hc.view)

            let bottomConstraint = hc.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
            bottomConstraint.priority = UILayoutPriority(999)

            NSLayoutConstraint.activate([
                hc.view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
                hc.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
                hc.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
                bottomConstraint
            ])

            hc.didMove(toParent: parentController)
            hc.onIdealHeightChanged = { [weak self] idealHeight in
                guard let self else { return }
                self.onCellIdealHeightChanged?(self, idealHeight + 12)
            }
            hostingController = hc
        }
    }
}

struct ChatMessagesTableView: UIViewControllerRepresentable {
    let conversationId: String
    let rows: [ChatListRowItem]
    let theme: AppThemePalette
    let isGenerating: Bool
    let autoFollowOutput: Bool
    let editingTurnId: String?
    let selectedTurnId: String?
    let scrollToBottomTrigger: Int
    let streamingState: StreamingTurnState
    let inspectorBridge: ChatTableInspectorBridge
    let onAutoFollowChanged: (Bool) -> Void
    let onUserScrollingChanged: (Bool) -> Void
    let onSelectToggle: (MessageDisplayTurn) -> Void
    let onEditBegin: (MessageDisplayTurn) -> Void
    let onEditEnd: (MessageDisplayTurn) -> Void
    let onDismissSelection: () -> Void
    let onEditSave: (MessageDisplayTurn, String) -> Void
    let onEditAndResend: (MessageDisplayTurn, String) -> Void
    let onRetryTurn: (MessageDisplayTurn) -> Void
    let onDeleteTurn: (MessageDisplayTurn) -> Void
    let onRetryLastFromError: () -> Void

    func makeUIViewController(context: Context) -> ChatMessagesTableViewController {
        let vc = ChatMessagesTableViewController()
        inspectorBridge.controller = vc
        vc.applyProps(self, isInitialMount: true)
        return vc
    }

    func updateUIViewController(_ uiViewController: ChatMessagesTableViewController, context: Context) {
        inspectorBridge.controller = uiViewController
        uiViewController.applyProps(self, isInitialMount: false)
    }
}

@MainActor
final class ChatMessagesTableViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    private let tableView = UITableView(frame: .zero, style: .plain)

    private var conversationId: String = ""
    private var rows: [ChatListRowItem] = []
    private var theme: AppThemePalette = SoftThemePreset.warmOat.palette
    private var isGenerating: Bool = false
    private var autoFollowOutput: Bool = true
    private var editingTurnId: String? = nil
    private var selectedTurnId: String? = nil
    private var lastScrollToBottomTrigger: Int = 0
    private var streamingState: StreamingTurnState?

    private var onAutoFollowChanged: ((Bool) -> Void)?
    private var onUserScrollingChanged: ((Bool) -> Void)?
    private var onSelectToggle: ((MessageDisplayTurn) -> Void)?
    private var onEditBegin: ((MessageDisplayTurn) -> Void)?
    private var onEditEnd: ((MessageDisplayTurn) -> Void)?
    private var onDismissSelection: (() -> Void)?
    private var onEditSave: ((MessageDisplayTurn, String) -> Void)?
    private var onEditAndResend: ((MessageDisplayTurn, String) -> Void)?
    private var onRetryTurn: ((MessageDisplayTurn) -> Void)?
    private var onDeleteTurn: ((MessageDisplayTurn) -> Void)?
    private var onRetryLastFromError: (() -> Void)?

    private var didPerformInitialBottomPlacement: Bool = false
    private var lastKnownBoundsSize: CGSize = .zero
    private var isProgrammaticOffsetChange: Bool = false
    private var isAnimatingToBottom: Bool = false
    private var isPerformingHeightPass: Bool = false
    private var preservesViewportOnNextHeightPass: Bool = false
    private var pendingViewportAnchor: (rowId: String, viewportMinY: CGFloat, fallbackOffsetY: CGFloat)?
    private var hasScheduledHeightPass: Bool = false
    private var lastScrollingHeightSyncTime: CFAbsoluteTime = 0
    private var deferredScrollingSyncItem: DispatchWorkItem?
    private var keyboardObservers: [NSObjectProtocol] = []
    private var lastReportedUserScrolling: Bool = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.allowsSelection = false
        tableView.showsVerticalScrollIndicator = true
        tableView.delaysContentTouches = false
        tableView.canCancelContentTouches = true
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 14, right: 0)
        tableView.verticalScrollIndicatorInsets = UIEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.sectionHeaderTopPadding = 0
        tableView.keyboardDismissMode = .interactive
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ChatHostingTableViewCell.self, forCellReuseIdentifier: ChatHostingTableViewCell.reuseIdentifier)

        let emptyAreaTap = UITapGestureRecognizer(target: self, action: #selector(handleEmptyBackgroundTap))
        emptyAreaTap.cancelsTouchesInView = false
        emptyAreaTap.delegate = self
        tableView.addGestureRecognizer(emptyAreaTap)

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let nc = NotificationCenter.default
        let showObs = nc.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleKeyboardDidShow()
            }
        }
        keyboardObservers = [showObs]
    }

    deinit {
        deferredScrollingSyncItem?.cancel()
        for obs in keyboardObservers {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    @objc private func handleEmptyBackgroundTap() {
        onDismissSelection?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: tableView)
        return tableView.indexPathForRow(at: point) == nil
    }

    private func handleKeyboardDidShow() {
        if let editingId = editingTurnId,
           let rowIdx = rows.firstIndex(where: { $0.turnId == editingId }) {
            let ip = IndexPath(row: rowIdx, section: 0)
            tableView.scrollToRow(at: ip, at: .middle, animated: true)
        } else if autoFollowOutput && !isUserInteracting {
            scrollToBottomImmediate()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = tableView.bounds.size
        guard size.width > 40 && size.height > 40 else { return }

        let widthChanged = abs(size.width - lastKnownBoundsSize.width) > 0.5
        let heightChanged = abs(size.height - lastKnownBoundsSize.height) > 0.5
        lastKnownBoundsSize = size

        if !didPerformInitialBottomPlacement {
            didPerformInitialBottomPlacement = true
            performInitialBottomPlacement()
            return
        }

        if widthChanged {
            // 横竖屏切换或分屏宽度改变：重排可见行
            UIView.performWithoutAnimation {
                for cell in tableView.visibleCells {
                    if let chatCell = cell as? ChatHostingTableViewCell,
                       let ip = tableView.indexPath(for: chatCell),
                       ip.row < rows.count {
                        configureCell(chatCell, with: rows[ip.row])
                    }
                }
                tableView.beginUpdates()
                tableView.endUpdates()
                if autoFollowOutput && !isUserInteracting {
                    scrollToBottomImmediate()
                }
            }
        } else if heightChanged && autoFollowOutput && !isUserInteracting && !isAnimatingToBottom && editingTurnId == nil {
            // 底部输入框变高或键盘弹起缩减可视区域高度时，保持贴底
            scrollToBottomImmediate()
        }
    }

    func applyProps(_ props: ChatMessagesTableView, isInitialMount: Bool) {
        let conversationSwitched = (!isInitialMount && self.conversationId != props.conversationId)
        let previousRows = self.rows
        let previousSelectedTurnId = self.selectedTurnId
        let triggerChanged = (!isInitialMount && props.scrollToBottomTrigger != self.lastScrollToBottomTrigger)

        self.conversationId = props.conversationId
        self.theme = props.theme
        self.isGenerating = props.isGenerating
        self.autoFollowOutput = props.autoFollowOutput
        self.editingTurnId = props.editingTurnId
        self.selectedTurnId = props.selectedTurnId
        self.lastScrollToBottomTrigger = props.scrollToBottomTrigger
        self.streamingState = props.streamingState

        self.onAutoFollowChanged = props.onAutoFollowChanged
        self.onUserScrollingChanged = props.onUserScrollingChanged
        self.onSelectToggle = props.onSelectToggle
        self.onEditBegin = props.onEditBegin
        self.onEditEnd = props.onEditEnd
        self.onDismissSelection = props.onDismissSelection
        self.onEditSave = props.onEditSave
        self.onEditAndResend = props.onEditAndResend
        self.onRetryTurn = props.onRetryTurn
        self.onDeleteTurn = props.onDeleteTurn
        self.onRetryLastFromError = props.onRetryLastFromError

        tableView.keyboardDismissMode = (props.editingTurnId == nil) ? .interactive : .none

        if isInitialMount {
            self.rows = props.rows
            return
        }

        if conversationSwitched {
            self.rows = props.rows
            didPerformInitialBottomPlacement = false
            if tableView.bounds.width > 40 && tableView.bounds.height > 40 {
                didPerformInitialBottomPlacement = true
                performInitialBottomPlacement()
            } else {
                tableView.reloadData()
            }
            return
        }

        applyRowDiff(from: previousRows, to: props.rows, previousSelectedTurnId: previousSelectedTurnId)

        if triggerChanged {
            scrollToBottomRequestedByUser()
        }
    }

    private func applyRowDiff(
        from oldRows: [ChatListRowItem],
        to newRows: [ChatListRowItem],
        previousSelectedTurnId: String?
    ) {
        guard oldRows != newRows else { return }
        let selectionChanged = selectedTurnId != previousSelectedTurnId
        if selectionChanged, let selectedTurnId = selectedTurnId {
            captureViewportAnchor(rowId: "turn_\(selectedTurnId)")
        }
        self.rows = newRows

        guard didPerformInitialBottomPlacement, tableView.window != nil else {
            tableView.reloadData()
            return
        }

        let oldIds = oldRows.map(\.id)
        let newIds = newRows.map(\.id)

        // 1. 行 ID 完全一致（例如点击选中弹出胶囊菜单、工具状态刷新、流式切换静态）：原地更新可见 Cell，保留内部展开态
        if oldIds == newIds {
            var anyVisibleChanged = false
            for i in newRows.indices where oldRows[i] != newRows[i] {
                let ip = IndexPath(row: i, section: 0)
                if let cell = tableView.cellForRow(at: ip) as? ChatHostingTableViewCell {
                    configureCell(cell, with: newRows[i])
                    if selectionChanged {
                        cell.refreshHostedContentImmediately()
                    }
                    anyVisibleChanged = true
                }
            }
            if anyVisibleChanged {
                if selectionChanged {
                    for cell in tableView.visibleCells.compactMap({ $0 as? ChatHostingTableViewCell }) {
                        cell.refreshHostedContentImmediately()
                    }
                    scheduleCellHeightPass(forceImmediate: true, preserveViewport: true, refreshHostedContent: true)
                }
                    performSeamlessCellHeightBatchUpdate(forceRevealLastRow: false)
                }
            }
            return
        }

        // 2. 纯尾部追加新行（例如发送新消息或新增生成状态行）
        if newIds.count > oldIds.count && Array(newIds.prefix(oldIds.count)) == oldIds {
            let insertedPaths = (oldIds.count..<newIds.count).map { IndexPath(row: $0, section: 0) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            UIView.performWithoutAnimation {
                for i in 0..<oldIds.count where oldRows[i] != newRows[i] {
                    let ip = IndexPath(row: i, section: 0)
                    if let cell = tableView.cellForRow(at: ip) as? ChatHostingTableViewCell {
                        configureCell(cell, with: newRows[i])
                    }
                }
                tableView.insertRows(at: insertedPaths, with: .none)
                tableView.layoutIfNeeded()
                if autoFollowOutput && !isUserInteracting {
                    scrollToBottomImmediate()
                }
            }
            CATransaction.commit()
            return
        }

        // 3. 删除消息 / 重试截断后续消息 / 清空
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            tableView.reloadData()
            tableView.layoutIfNeeded()
            if autoFollowOutput && !isUserInteracting && !newRows.isEmpty {
                scrollToBottomImmediate()
            } else {
                clampOffsetIfNeeded()
            }
        }
        CATransaction.commit()
    }

    private func performInitialBottomPlacement() {
        guard !rows.isEmpty else {
            tableView.reloadData()
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            tableView.reloadData()
            let lastIp = IndexPath(row: rows.count - 1, section: 0)
            tableView.scrollToRow(at: lastIp, at: .bottom, animated: false)
            tableView.layoutIfNeeded()
            // 二次精确贴底校准：底部可见 Cell 已完成真实尺寸测量，消除任何预估高度误差
            tableView.scrollToRow(at: lastIp, at: .bottom, animated: false)
            tableView.layoutIfNeeded()
            scrollToBottomImmediate()
        }
        CATransaction.commit()
    }

    private var rowAvailableWidth: CGFloat {
        let baseWidth = tableView.bounds.width > 40 ? tableView.bounds.width : UIScreen.main.bounds.width
        return max(260, baseWidth - 20)
    }

    private var isUserInteracting: Bool {
        tableView.isTracking || tableView.isDragging || tableView.isDecelerating
    }

    private func exactBottomOffset() -> CGFloat {
        let minOffset = -tableView.adjustedContentInset.top
        let maxOffset = tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
        return max(minOffset, maxOffset)
    }

    private func clampOffsetIfNeeded() {
        let minOffset = -tableView.adjustedContentInset.top
        let maxOffset = exactBottomOffset()
        if tableView.contentOffset.y > maxOffset + 0.5 {
            setContentOffsetProgrammatically(maxOffset)
        } else if tableView.contentOffset.y < minOffset - 0.5 {
            setContentOffsetProgrammatically(minOffset)
        }
    }

    private func setContentOffsetProgrammatically(_ targetY: CGFloat) {
        guard abs(tableView.contentOffset.y - targetY) > 0.5 else { return }
        isProgrammaticOffsetChange = true
        tableView.contentOffset = CGPoint(x: 0, y: targetY)
        isProgrammaticOffsetChange = false
    }

    private func scrollToBottomImmediate() {
        guard !rows.isEmpty, tableView.bounds.height > 20 else { return }
        let lastIp = IndexPath(row: rows.count - 1, section: 0)
        // 若最后一行尚未在可视区实例化，先用 scrollToRow 挂载最后一行再精确对齐底边
        if tableView.indexPathsForVisibleRows?.contains(lastIp) != true {
            isProgrammaticOffsetChange = true
            tableView.scrollToRow(at: lastIp, at: .bottom, animated: false)
            tableView.layoutIfNeeded()
            isProgrammaticOffsetChange = false
        }
        setContentOffsetProgrammatically(exactBottomOffset())
    }

    private func scrollToBottomRequestedByUser() {
        guard !rows.isEmpty, tableView.bounds.height > 20 else { return }
        autoFollowOutput = true
        reportUserScrolling(false)

        let lastIp = IndexPath(row: rows.count - 1, section: 0)
        let currentY = tableView.contentOffset.y
        let estimatedTargetY = exactBottomOffset()

        if abs(estimatedTargetY - currentY) <= 2 && tableView.indexPathsForVisibleRows?.contains(lastIp) == true {
            return
        }

        // 若距离底部超过 2 屏，先无动画跳到倒数第 2 屏附近再平滑滑到底部，避免长距离滚过大量历史 Cell 掉帧
        if estimatedTargetY - currentY > tableView.bounds.height * 2.0 {
            UIView.performWithoutAnimation {
                let jumpRow = max(0, rows.count - 3)
                tableView.scrollToRow(at: IndexPath(row: jumpRow, section: 0), at: .bottom, animated: false)
                tableView.layoutIfNeeded()
            }
        }

        isAnimatingToBottom = true
        tableView.scrollToRow(at: lastIp, at: .bottom, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self else { return }
            self.isAnimatingToBottom = false
            if self.autoFollowOutput && !self.isUserInteracting {
                UIView.performWithoutAnimation {
                    self.tableView.layoutIfNeeded()
                    self.scrollToBottomImmediate()
                }
            }
        }
    }

    private var hasPendingDeferredHeightRefresh: Bool = false

    private func captureViewportAnchor(rowId: String) {
        guard let rowIndex = rows.firstIndex(where: { $0.id == rowId }) else { return }
        let indexPath = IndexPath(row: rowIndex, section: 0)
        guard let visiblePaths = tableView.indexPathsForVisibleRows, visiblePaths.contains(indexPath) else { return }
        let rowRect = tableView.rectForRow(at: indexPath)
        pendingViewportAnchor = (
            rowId: rowId,
            viewportMinY: rowRect.minY - tableView.contentOffset.y,
            fallbackOffsetY: tableView.contentOffset.y
        )
    }

    private func scheduleCellHeightPass(
        forceImmediate: Bool = false,
        preserveViewport: Bool = false,
        refreshHostedContent: Bool = false
    ) {
        guard didPerformInitialBottomPlacement, tableView.window != nil else { return }
        preservesViewportOnNextHeightPass = preservesViewportOnNextHeightPass || preserveViewport

        if !forceImmediate && (tableView.isDragging || tableView.isDecelerating) {
            hasPendingDeferredHeightRefresh = true
            return
        }

        guard !hasScheduledHeightPass else { return }
        hasScheduledHeightPass = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasScheduledHeightPass = false
            if !forceImmediate && (self.tableView.isDragging || self.tableView.isDecelerating) {
                self.hasPendingDeferredHeightRefresh = true
                return
            }
            self.hasPendingDeferredHeightRefresh = false
            let preserveViewport = self.preservesViewportOnNextHeightPass
            self.preservesViewportOnNextHeightPass = false
            if refreshHostedContent {
                if let anchor = self.pendingViewportAnchor,
                   let rowIndex = self.rows.firstIndex(where: { $0.id == anchor.rowId }),
                   let cell = self.tableView.cellForRow(at: IndexPath(row: rowIndex, section: 0)) as? ChatHostingTableViewCell {
                    cell.refreshHostedContentImmediately()
                }
            }
            self.tableView.layoutIfNeeded()
            self.performSeamlessCellHeightBatchUpdate(
                forceRevealLastRow: false,
                preserveViewport: preserveViewport
            )
        }
    }

    private func performSeamlessCellHeightBatchUpdate(
        forceRevealLastRow: Bool,
        preserveViewport: Bool = false
    ) {
        guard didPerformInitialBottomPlacement, tableView.window != nil, !rows.isEmpty else { return }

        let shouldPinBottom = !preserveViewport && ((autoFollowOutput && !isUserInteracting && !isAnimatingToBottom) || forceRevealLastRow)
        let firstVisiblePath: IndexPath? = {
            guard preserveViewport, let anchor = pendingViewportAnchor,
                  let rowIndex = rows.firstIndex(where: { $0.id == anchor.rowId }) else { return nil }
            let indexPath = IndexPath(row: rowIndex, section: 0)
            return tableView.indexPathsForVisibleRows?.contains(indexPath) == true ? indexPath : nil
        }()
        let anchor = pendingViewportAnchor
        let fallbackOffsetY = anchor?.fallbackOffsetY ?? tableView.contentOffset.y

        isPerformingHeightPass = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            tableView.layoutIfNeeded()
            tableView.beginUpdates()
            tableView.endUpdates()
            tableView.layoutIfNeeded()

            if let firstVisiblePath = firstVisiblePath,
               let anchor = anchor,
               firstVisiblePath.row < rows.count {
                let newMinY = tableView.rectForRow(at: firstVisiblePath).minY
                setContentOffsetProgrammatically(newMinY - anchor.viewportMinY)
                pendingViewportAnchor = nil
            } else if preserveViewport {
                setContentOffsetProgrammatically(min(fallbackOffsetY, exactBottomOffset()))
                pendingViewportAnchor = nil
            } else if shouldPinBottom {
                scrollToBottomImmediate()
            }

            for cell in tableView.visibleCells {
                if let chatCell = cell as? ChatHostingTableViewCell {
                    ChatRowHeightCache.shared.store(
                        chatCell.bounds.height,
                        conversationId: conversationId,
                        rowId: chatCell.currentRowId,
                        width: rowAvailableWidth
                    )
                }
            }
        }
        CATransaction.commit()
        isPerformingHeightPass = false
    }

    private func configureCell(_ cell: ChatHostingTableViewCell, with item: ChatListRowItem) {
        guard let streaming = streamingState else { return }
        let width = rowAvailableWidth
        let rootView = ChatRowHostedView(
            item: item,
            theme: theme,
            rowAvailableWidth: width,
            streamingState: streaming,
            onSelectToggle: { [weak self] turn in self?.onSelectToggle?(turn) },
            onEditBegin: { [weak self] turn in self?.onEditBegin?(turn) },
            onEditEnd: { [weak self] turn in self?.onEditEnd?(turn) },
            onDismissSelection: { [weak self] in self?.onDismissSelection?() },
            onEditSave: { [weak self] turn, text in self?.onEditSave?(turn, text) },
            onEditAndResend: { [weak self] turn, text in self?.onEditAndResend?(turn, text) },
            onRetryTurn: { [weak self] turn in self?.onRetryTurn?(turn) },
            onDeleteTurn: { [weak self] turn in self?.onDeleteTurn?(turn) },
            onRetryLastFromError: { [weak self] in self?.onRetryLastFromError?() },
            onIntrinsicLayoutInvalidated: { [weak self, weak cell] in
                guard let self, let cell else { return }
                self.captureViewportAnchor(rowId: cell.currentRowId)
                self.scheduleCellHeightPass(forceImmediate: true, preserveViewport: true)
            }
        )

        cell.onCellIdealHeightChanged = { [weak self] targetCell, idealCellHeight in
            guard let self else { return }
            ChatRowHeightCache.shared.store(
                idealCellHeight,
                conversationId: self.conversationId,
                rowId: targetCell.currentRowId,
                width: self.rowAvailableWidth
            )
            guard !self.isPerformingHeightPass else { return }
            if abs(targetCell.bounds.height - idealCellHeight) > 0.5 {
                self.scheduleCellHeightPass()
            }
        }

        cell.configure(rootView: rootView, rowId: item.id, parentController: self)
        cell.contentView.setNeedsLayout()
        cell.contentView.layoutIfNeeded()
        cell.hostedView?.setNeedsLayout()
        cell.hostedView?.layoutIfNeeded()
    }

    // MARK: - UITableViewDataSource & UITableViewDelegate

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard indexPath.row < rows.count else { return 64 }
        let item = rows[indexPath.row]
        let width = rowAvailableWidth
        if let cached = ChatRowHeightCache.shared.height(conversationId: conversationId, rowId: item.id, width: width) {
            return cached
        }
        return ChatRowHeightCache.estimate(for: item, rowWidth: width)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: ChatHostingTableViewCell.reuseIdentifier,
            for: indexPath
        ) as? ChatHostingTableViewCell else {
            return UITableViewCell()
        }
        if indexPath.row < rows.count {
            configureCell(cell, with: rows[indexPath.row])
        }
        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let chatCell = cell as? ChatHostingTableViewCell else { return }
        DispatchQueue.main.async { [weak self, weak chatCell] in
            guard let self, let chatCell, chatCell.bounds.height > 16 else { return }
            ChatRowHeightCache.shared.store(
                chatCell.bounds.height,
                conversationId: self.conversationId,
                rowId: chatCell.currentRowId,
                width: self.rowAvailableWidth
            )
        }
    }

    // MARK: - UIScrollViewDelegate

    private func reportUserScrolling(_ scrolling: Bool) {
        guard lastReportedUserScrolling != scrolling else { return }
        lastReportedUserScrolling = scrolling
        onUserScrollingChanged?(scrolling)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isAnimatingToBottom = false
        reportUserScrolling(true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isProgrammaticOffsetChange, !isAnimatingToBottom, didPerformInitialBottomPlacement else { return }
        let distanceFromBottom = exactBottomOffset() - scrollView.contentOffset.y

        if isUserInteracting {
            // 手指向上推离底部超过 22pt 即立即解除自动贴底，绝不回拉抢手势
            if distanceFromBottom > 22 && autoFollowOutput {
                autoFollowOutput = false
                onAutoFollowChanged?(false)
            } else if distanceFromBottom <= 10 && !autoFollowOutput && !scrollView.isDragging {
                autoFollowOutput = true
                onAutoFollowChanged?(true)
            }
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            handleUserScrollDidSettle()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        handleUserScrollDidSettle()
    }

    private func handleUserScrollDidSettle() {
        let distanceFromBottom = exactBottomOffset() - tableView.contentOffset.y
        if distanceFromBottom <= 18 && !autoFollowOutput {
            autoFollowOutput = true
            onAutoFollowChanged?(true)
        }
        reportUserScrolling(false)
        if hasPendingDeferredHeightRefresh {
            hasPendingDeferredHeightRefresh = false
            scheduleCellHeightPass(forceImmediate: true)
        }
    }

    // MARK: - 诊断报告生成

    func buildDiagnosticsReport(selectedTurnId: String?) -> String {
        var lines: [String] = [
            "OpenMCP 对话布局诊断报告 (UIKit 原生表格引擎)",
            "采集时间：\(ISO8601DateFormatter().string(from: Date()))",
            "总行数：\(rows.count)，可视区尺寸：\(String(format: "%.1f x %.1f", tableView.bounds.width, tableView.bounds.height))",
            "contentSize：\(String(format: "%.1f x %.1f", tableView.contentSize.width, tableView.contentSize.height))，contentOffset.y：\(String(format: "%.1f", tableView.contentOffset.y))",
            "隐私：不包含对话正文、工具参数、工具结果或密钥。",
            ""
        ]

        let visiblePaths = (tableView.indexPathsForVisibleRows ?? []).sorted()
        lines.append("当前屏幕可见行 (\(visiblePaths.count) 行)：")

        var prevRect: CGRect?
        for ip in visiblePaths where ip.row < rows.count {
            let rect = tableView.rectForRow(at: ip)
            let item = rows[ip.row]
            lines.append("[\(ip.row + 1)/\(rows.count)] \(item.id.prefix(16)) frame=(x=\(String(format: "%.1f", rect.minX)), y=\(String(format: "%.1f", rect.minY)), w=\(String(format: "%.1f", rect.width)), h=\(String(format: "%.1f", rect.height)))")
            if let prev = prevRect {
                lines.append("  与上一行物理间距：\(String(format: "%.1f", rect.minY - prev.maxY)) pt (含上下各 6pt 边距共 12pt)")
            }
            prevRect = rect
        }

        return lines.joined(separator: "\n")
    }
}

private extension SoftThemePreset {
    var palette: AppThemePalette {
        AppThemePalette.make(backgroundHex: backgroundHex, accentHex: accentHex)
    }
}
