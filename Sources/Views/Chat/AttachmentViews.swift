import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import PDFKit

struct ThinkingStatusView: View {
    let statusText: String
    let startDate: Date
    let theme: AppThemePalette
    var isPaused: Bool = false

    var body: some View {
        Group {
            if isPaused {
                statusContent(elapsed: max(0, Date().timeIntervalSince(startDate)))
            } else {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    statusContent(elapsed: max(0, context.date.timeIntervalSince(startDate)))
                }
            }
        }
    }

    private func statusContent(elapsed: TimeInterval) -> some View {
        HStack(spacing: 7) {
            Text(statusText.isEmpty ? "思考中" : statusText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = (sin(elapsed * 2.5 - Double(index) * 0.9) + 1.0) * 0.5
                    Circle()
                        .fill(theme.accent.opacity(0.28 + 0.72 * wave))
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.84 + 0.30 * wave)
                }
            }

            Text(Self.formatElapsed(elapsed))
                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundColor(theme.secondaryText)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(mins)m \(secs)s"
        }
    }
}

struct AttachmentFileCardView: View {
    let attachment: ChatAttachment
    let theme: AppThemePalette
    var isSelected: Bool = false
    var onCardTap: () -> Void
    var onPreviewTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(theme.accent.opacity(0.14))
                        .frame(width: 34, height: 34)
                    Image(systemName: attachment.iconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(theme.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.fileName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    Text(attachment.metadataSummary)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 3) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                    Text("查看")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundColor(theme.accent)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 5.5)
                .background(theme.accent.opacity(0.12))
                .clipShape(Capsule())
                .contentShape(Capsule())
                .onTapGesture {
                    onPreviewTap()
                }
            }

            if !attachment.previewSnippet.isEmpty {
                Text(attachment.previewSnippet)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(theme.elevatedBackground.opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(10)
        .frame(maxWidth: 280, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? theme.accent.opacity(0.55) : theme.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            onCardTap()
        }
    }
}

struct AttachmentImageGridView: View {
    let attachments: [ChatAttachment]
    let theme: AppThemePalette
    var isSelected: Bool = false
    var onCardTap: () -> Void
    var onSelectImage: (ChatAttachment) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(attachments) { att in
                if let b64 = att.imageDataBase64,
                   let data = Data(base64Encoded: b64),
                   let uiImage = UIImage(data: data) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: attachments.count == 1 ? 170 : 100,
                                height: attachments.count == 1 ? 170 : 100
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(isSelected ? theme.accent.opacity(0.55) : theme.border, lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onTapGesture {
                                onCardTap()
                            }

                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 9.5, weight: .bold))
                            Text("查看")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.58))
                        .clipShape(Capsule())
                        .padding(6)
                        .contentShape(Capsule())
                        .onTapGesture {
                            onSelectImage(att)
                        }
                    }
                }
            }
        }
    }
}

struct NativeCodeTextView: UIViewRepresentable {
    let text: String
    let wrapLines: Bool
    let theme: AppThemePalette

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.alwaysBounceVertical = true
        tv.showsVerticalScrollIndicator = true
        tv.showsHorizontalScrollIndicator = true
        tv.textContainerInset = UIEdgeInsets(top: 14, left: 14, bottom: 24, right: 14)
        tv.font = UIFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
        tv.layoutManager.allowsNonContiguousLayout = true
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.backgroundColor = UIColor(theme.background)
        uiView.textColor = UIColor(theme.primaryText)
        uiView.tintColor = UIColor(theme.accent)

        if context.coordinator.lastWrapLines != wrapLines {
            context.coordinator.lastWrapLines = wrapLines
            if wrapLines {
                uiView.textContainer.widthTracksTextView = true
                uiView.textContainer.size = CGSize(width: uiView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
                uiView.alwaysBounceHorizontal = false
            } else {
                uiView.textContainer.widthTracksTextView = false
                uiView.textContainer.size = CGSize(width: CGFloat(20_000), height: CGFloat.greatestFiniteMagnitude)
                uiView.alwaysBounceHorizontal = true
            }
        }

        if context.coordinator.lastText != text {
            context.coordinator.lastText = text
            uiView.text = text
        }
    }

    final class Coordinator {
        var lastText: String?
        var lastWrapLines: Bool?
    }
}

struct AttachmentFilePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: ChatAttachment
    let theme: AppThemePalette
    @State private var isCopied: Bool = false
    @State private var wrapLines: Bool = true
    @State private var searchQuery: String = ""

    private var fullText: String {
        attachment.textContent ?? "（该文件为二进制或无文本内容）"
    }

    private var displayedText: String {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return fullText }
        let matchedLines = fullText
            .components(separatedBy: .newlines)
            .enumerated()
            .filter { $0.element.localizedCaseInsensitiveContains(q) }
            .map { "[\($0.offset + 1)] \($0.element)" }
        return matchedLines.isEmpty ? "未找到包含“\(q)”的内容行" : matchedLines.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Label(attachment.metadataSummary, systemImage: attachment.iconName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)

                        Spacer()

                        Button(action: {
                            wrapLines.toggle()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: wrapLines ? "text.alignleft" : "arrow.left.and.right.text.vertical")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(wrapLines ? "自动换行" : "横向滚动")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundColor(theme.accent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(theme.accent.opacity(0.12))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            UIPasteboard.general.string = fullText
                            withAnimation { isCopied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { isCopied = false }
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(isCopied ? "已复制" : "复制全文")
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundColor(isCopied ? .white : theme.primaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(isCopied ? theme.accent : theme.cardBackground)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(theme.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(theme.elevatedBackground)

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundColor(theme.mutedText)
                        TextField("在文件中搜索关键词...", text: $searchQuery)
                            .font(.system(size: 13.5))
                            .foregroundColor(theme.primaryText)
                        if !searchQuery.isEmpty {
                            Button(action: { searchQuery = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(theme.mutedText)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(theme.cardBackground)
                    .overlay(
                        Rectangle()
                            .fill(theme.border)
                            .frame(height: 1),
                        alignment: .bottom
                    )

                    NativeCodeTextView(
                        text: displayedText,
                        wrapLines: wrapLines,
                        theme: theme
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(attachment.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: fullText, subject: Text(attachment.fileName)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.accent)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct AttachmentImagePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: ChatAttachment
    let theme: AppThemePalette
    @State private var scale: CGFloat = 1.0

    private var uiImage: UIImage? {
        guard let b64 = attachment.imageDataBase64,
              let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let img = uiImage {
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: UIScreen.main.bounds.width * scale)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { val in
                                        scale = min(max(val, 1.0), 4.0)
                                    }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    scale = scale > 1.0 ? 1.0 : 2.2
                                }
                            }
                    }
                } else {
                    Text("无法加载图片数据")
                        .foregroundColor(.white)
                }
            }
            .navigationTitle(attachment.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let img = uiImage {
                        Button(action: {
                            UIPasteboard.general.image = img
                        }) {
                            Label("复制图片", systemImage: "doc.on.doc")
                                .foregroundColor(.white)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
        }
    }
}

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    var onSelectImages: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 6
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectImages: onSelectImages)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onSelectImages: ([UIImage]) -> Void

        init(onSelectImages: @escaping ([UIImage]) -> Void) {
            self.onSelectImages = onSelectImages
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }

            let group = DispatchGroup()
            var images: [UIImage] = []
            let lock = NSLock()

            for result in results {
                let provider = result.itemProvider
                if provider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    provider.loadObject(ofClass: UIImage.self) { object, _ in
                        if let img = object as? UIImage {
                            lock.lock()
                            images.append(img)
                            lock.unlock()
                        }
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) {
                if !images.isEmpty {
                    self.onSelectImages(images)
                }
            }
        }
    }
}

struct CameraImagePicker: UIViewControllerRepresentable {
    var onCaptureImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
        } else {
            picker.sourceType = .photoLibrary
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCaptureImage: onCaptureImage)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCaptureImage: (UIImage) -> Void

        init(onCaptureImage: @escaping (UIImage) -> Void) {
            self.onCaptureImage = onCaptureImage
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            picker.dismiss(animated: true)
            if let img = info[.originalImage] as? UIImage {
                onCaptureImage(img)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

struct DocumentFilePicker: UIViewControllerRepresentable {
    var onPickURLs: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .data, .content], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPickURLs: onPickURLs)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPickURLs: ([URL]) -> Void

        init(onPickURLs: @escaping ([URL]) -> Void) {
            self.onPickURLs = onPickURLs
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPickURLs(urls)
        }
    }
}

enum AttachmentProcessor {
    static func processUIImage(_ image: UIImage, index: Int) -> ChatAttachment? {
        let maxDimension: CGFloat = 1280
        let size = image.size
        var targetSize = size
        if max(size.width, size.height) > maxDimension {
            let ratio = maxDimension / max(size.width, size.height)
            targetSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        }

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        guard let jpegData = resized.jpegData(compressionQuality: 0.78) else { return nil }
        return ChatAttachment(
            kind: .image,
            fileName: "图片_\(index).jpg",
            mimeType: "image/jpeg",
            fileSize: jpegData.count,
            imageDataBase64: jpegData.base64EncodedString()
        )
    }

    static func processFileURL(_ url: URL) -> ChatAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        guard let data = try? Data(contentsOf: url) else { return nil }
        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "gif", "bmp"]
        if imageExts.contains(ext), let img = UIImage(data: data) {
            if var att = processUIImage(img, index: 1) {
                att.fileName = fileName
                return att
            }
        }

        if ext == "pdf", let pdf = PDFDocument(url: url) {
            var pagesText: [String] = []
            for i in 0..<pdf.pageCount {
                if let pageStr = pdf.page(at: i)?.string, !pageStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    pagesText.append("--- 第 \(i + 1) 页 ---\n\(pageStr)")
                }
            }
            let joined = pagesText.joined(separator: "\n\n")
            return ChatAttachment(
                kind: .file,
                fileName: fileName,
                mimeType: "application/pdf",
                fileSize: data.count,
                textContent: joined.isEmpty ? "（PDF 未提取到可复制文本）" : joined
            )
        }

        let encodings: [String.Encoding] = [.utf8, .gb18030, .utf16, .ascii, .isoLatin1]
        for enc in encodings {
            if let decoded = String(data: data, encoding: enc) {
                let capped = decoded.count > 120_000 ? String(decoded.prefix(120_000)) + "\n...(文件内容过长已截断)..." : decoded
                return ChatAttachment(
                    kind: .file,
                    fileName: fileName,
                    mimeType: "text/plain",
                    fileSize: data.count,
                    textContent: capped
                )
            }
        }

        return ChatAttachment(
            kind: .file,
            fileName: fileName,
            mimeType: "application/octet-stream",
            fileSize: data.count,
            textContent: "（二进制文件 \(fileName)，大小 \(data.count) 字节）"
        )
    }
}

extension String.Encoding {
    static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )
}
