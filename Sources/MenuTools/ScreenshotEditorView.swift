import AppKit
import CoreGraphics
import CoreImage
import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private enum ScreenshotEditorTool: String, CaseIterable, Identifiable {
    case crop
    case pen
    case arrow
    case rectangle
    case ellipse
    case highlight
    case mosaic
    case text

    var id: String { rawValue }

    var titleKey: String { "screenshot.editor.tool.\(rawValue)" }

    var symbol: String {
        switch self {
        case .crop: return "crop"
        case .pen: return "pencil"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .highlight: return "highlighter"
        case .mosaic: return "square.grid.3x3"
        case .text: return "textformat"
        }
    }
}

enum ScreenshotEditorColor: String, CaseIterable, Identifiable, Hashable {
    case red
    case yellow
    case blue
    case black
    case white

    var id: String { rawValue }

    var titleKey: String { "screenshot.editor.color.\(rawValue)" }

    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .yellow: return .systemYellow
        case .blue: return .systemBlue
        case .black: return .black
        case .white: return .white
        }
    }

    var swiftUIColor: Color { Color(nsColor: nsColor) }
}

private enum ScreenshotEditorAnnotation {
    case freehand(points: [CGPoint], color: ScreenshotEditorColor, lineWidth: CGFloat)
    case arrow(start: CGPoint, end: CGPoint, color: ScreenshotEditorColor, lineWidth: CGFloat)
    case rectangle(rect: CGRect, color: ScreenshotEditorColor, lineWidth: CGFloat)
    case ellipse(rect: CGRect, color: ScreenshotEditorColor, lineWidth: CGFloat)
    case highlight(rect: CGRect, color: ScreenshotEditorColor)
    case mosaic(rect: CGRect)
    case text(value: String, point: CGPoint, color: ScreenshotEditorColor)
}

private enum ScreenshotEditorDraft {
    case crop(rect: CGRect)
    case freehand(points: [CGPoint])
    case line(start: CGPoint, end: CGPoint)
    case rectangle(rect: CGRect)
    case ellipse(rect: CGRect)
    case highlight(rect: CGRect)
    case mosaic(rect: CGRect)
}

/// 截图应用内编辑器，参考 Snapzy 的标注工具组织方式实现。
///
/// 编辑结果由本应用直接合成 PNG，不会打开 Preview 或其它系统编辑器。
struct ScreenshotEditorView: View {
    let session: ScreenshotEditorSession
    let onSave: (Data) throws -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tool: ScreenshotEditorTool = .pen
    @State private var imageData: Data
    @State private var color: ScreenshotEditorColor = .red
    @State private var isColorPalettePresented = false
    @State private var lineWidth: Double = 4
    @State private var annotations: [ScreenshotEditorAnnotation] = []
    @State private var draft: ScreenshotEditorDraft?
    @State private var gestureStart: CGPoint?
    @State private var textPosition: CGPoint?
    @State private var textValue = ""
    @State private var editingTextIndex: Int?
    @FocusState private var textFieldFocused: Bool
    @State private var errorMessage: String?

    init(
        session: ScreenshotEditorSession,
        onSave: @escaping (Data) throws -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.session = session
        self.onSave = onSave
        self.onCancel = onCancel
        _imageData = State(initialValue: session.imageData)
    }

    private var sourceImage: CGImage? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { proxy in
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    if let sourceImage {
                        Image(nsImage: NSImage(
                            cgImage: sourceImage,
                            size: NSSize(width: sourceImage.width, height: sourceImage.height)
                        ))
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Canvas { context, size in
                            draw(
                                annotations: annotations,
                                draft: draft,
                                editingTextIndex: editingTextIndex,
                                in: &context,
                                size: size
                            )
                        }
                        .allowsHitTesting(false)

                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(drawingGesture(in: proxy.size))

                        if textPosition != nil {
                            inlineTextEditor(in: proxy.size, image: sourceImage)
                        }
                    } else {
                        ContentUnavailableView(
                            L("screenshot.error.noImage"),
                            systemImage: "photo.badge.exclamationmark"
                        )
                    }
                }
                .padding(18)
            }
            .background(.black.opacity(0.08))
        }
        .frame(minWidth: 800, minHeight: 560)
        .onExitCommand { cancelTextEditing() }
        .alert(
            L("screenshot.error.editor"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(L("update.cancel"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? L("screenshot.error.editor"))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label(L("screenshot.editor.title"), systemImage: "pencil.and.outline")
                .font(.headline)

            Divider().frame(height: 22)

            Menu {
                ForEach(ScreenshotEditorTool.allCases) { item in
                    Button {
                        if item != .text {
                            commitTextEditing()
                        }
                        tool = item
                    } label: {
                        Label(L(item.titleKey), systemImage: item.symbol)
                    }
                }
            } label: {
                Label(L(tool.titleKey), systemImage: tool.symbol)
            }
            .help(L("screenshot.editor.tool"))

            Button {
                isColorPalettePresented.toggle()
            } label: {
                HStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(color.swiftUIColor)
                        Circle()
                            .stroke(.primary.opacity(0.3), lineWidth: 0.5)
                    }
                    .frame(width: 15, height: 15)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .padding(4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $isColorPalettePresented, arrowEdge: .bottom) {
                colorPalette
            }
            .help(L("screenshot.editor.color"))

            if tool != .text && tool != .mosaic && tool != .crop {
                Slider(value: $lineWidth, in: 2...16, step: 1)
                    .frame(width: 80)
                    .help(L("screenshot.editor.width"))
            }

            Button {
                rotateImage(clockwise: false)
            } label: {
                Image(systemName: "rotate.left")
            }
            .buttonStyle(.borderless)
            .help(L("screenshot.editor.rotateLeft"))

            Button {
                rotateImage(clockwise: true)
            } label: {
                Image(systemName: "rotate.right")
            }
            .buttonStyle(.borderless)
            .help(L("screenshot.editor.rotateRight"))

            Button {
                recognizeText()
            } label: {
                Label(L("screenshot.ocr.copy"), systemImage: "text.viewfinder")
            }
            .disabled(sourceImage == nil)
            .help(L("screenshot.ocr.copy"))

            Spacer()

            Button {
                undo()
            } label: {
                Label(L("screenshot.editor.undo"), systemImage: "arrow.uturn.backward")
            }
            .disabled(annotations.isEmpty)

            Button {
                commitTextEditing()
                annotations.removeAll()
                draft = nil
            } label: {
                Label(L("screenshot.editor.clear"), systemImage: "trash")
            }
            .disabled(annotations.isEmpty && draft == nil)

            Button(L("update.cancel"), role: .cancel) {
                cancelTextEditing()
                onCancel()
                dismiss()
            }

            Button(L("screenshot.editor.save"), systemImage: "checkmark.circle.fill") {
                commitTextEditing()
                save()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }

    private var colorPalette: some View {
        HStack(spacing: 12) {
            ForEach(ScreenshotEditorColor.allCases) { item in
                Button {
                    color = item
                    isColorPalettePresented = false
                } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle()
                                .fill(item.swiftUIColor)
                                .frame(width: 24, height: 24)
                                .overlay {
                                    Circle().stroke(.primary.opacity(0.3), lineWidth: 0.75)
                                }
                            if color == item {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(item == .black ? .white : .primary)
                            }
                        }
                        Text(L(item.titleKey))
                            .font(.caption2)
                            .foregroundStyle(.primary)
                    }
                    .frame(width: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L(item.titleKey))
            }
        }
        .padding(12)
    }

    private func drawingGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let sourceImage,
                      let point = normalizedPoint(value.location, in: size, image: sourceImage) else {
                    return
                }

                if tool == .text {
                    return
                }
                if gestureStart == nil {
                    gestureStart = point
                }
                let start = gestureStart ?? point
                switch tool {
                case .pen:
                    if case let .freehand(points) = draft {
                        draft = .freehand(points: points + [point])
                    } else {
                        draft = .freehand(points: [point])
                    }
                case .arrow:
                    draft = .line(start: start, end: point)
                case .rectangle:
                    draft = .rectangle(rect: normalizedRect(from: start, to: point))
                case .ellipse:
                    draft = .ellipse(rect: normalizedRect(from: start, to: point))
                case .highlight:
                    draft = .highlight(rect: normalizedRect(from: start, to: point))
                case .mosaic:
                    draft = .mosaic(rect: normalizedRect(from: start, to: point))
                case .crop:
                    draft = .crop(rect: normalizedRect(from: start, to: point))
                case .text:
                    break
                }
            }
            .onEnded { value in
                guard let sourceImage,
                      let point = normalizedPoint(value.location, in: size, image: sourceImage) else {
                    draft = nil
                    gestureStart = nil
                    return
                }

                if tool == .text {
                    beginTextEditing(at: point, in: size, image: sourceImage)
                    gestureStart = nil
                    return
                }
                commitDraft()
                gestureStart = nil
            }
    }

    private func commitDraft() {
        guard let draft else { return }
        switch draft {
        case let .crop(rect) where rect.width >= 0.02 && rect.height >= 0.02:
            applyCrop(rect)
        case let .freehand(points) where !points.isEmpty:
            annotations.append(.freehand(points: points, color: color, lineWidth: lineWidth))
        case let .line(start, end):
            annotations.append(.arrow(start: start, end: end, color: color, lineWidth: lineWidth))
        case let .rectangle(rect) where rect.width >= 0.005 && rect.height >= 0.005:
            annotations.append(.rectangle(rect: rect, color: color, lineWidth: lineWidth))
        case let .ellipse(rect) where rect.width >= 0.005 && rect.height >= 0.005:
            annotations.append(.ellipse(rect: rect, color: color, lineWidth: lineWidth))
        case let .highlight(rect) where rect.width >= 0.005 && rect.height >= 0.005:
            annotations.append(.highlight(rect: rect, color: color))
        case let .mosaic(rect) where rect.width >= 0.005 && rect.height >= 0.005:
            annotations.append(.mosaic(rect: rect))
        default:
            break
        }
        self.draft = nil
    }

    private func inlineTextEditor(in size: CGSize, image: CGImage) -> some View {
        let canvasRect = imageRect(in: size, image: image)
        let point = map(textPosition ?? .zero, in: canvasRect)
        let fontSize = max(14, min(28, canvasRect.width / 30))

        return TextField("", text: $textValue)
            .textFieldStyle(.plain)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(color.swiftUIColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(width: min(320, max(160, canvasRect.width * 0.45)))
            .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(.white.opacity(0.75), lineWidth: 1)
            }
            .focused($textFieldFocused)
            .onSubmit { commitTextEditing() }
            .onAppear {
                // SwiftUI 需要在 TextField 真正加入窗口后再设置焦点。
                DispatchQueue.main.async {
                    textFieldFocused = true
                }
            }
            .position(
                x: point.x + min(320, max(160, canvasRect.width * 0.45)) / 2,
                y: point.y + fontSize / 2 + 6
            )
    }

    private func beginTextEditing(at point: CGPoint, in size: CGSize, image: CGImage) {
        // 点击其它位置时，先保留刚刚输入的内容，再开始新的文字标注。
        if textPosition != nil {
            commitTextEditing()
        }

        let canvasRect = imageRect(in: size, image: image)
        if let index = textAnnotationIndex(at: point, imageRect: canvasRect) {
            guard case let .text(value, position, annotationColor) = annotations[index] else {
                return
            }
            editingTextIndex = index
            textPosition = position
            textValue = value
            color = annotationColor
        } else {
            editingTextIndex = nil
            textPosition = point
            textValue = ""
        }

        textFieldFocused = false
        DispatchQueue.main.async {
            textFieldFocused = true
        }
    }

    private func commitTextEditing() {
        guard let textPosition else { return }
        let value = textValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if let editingTextIndex,
           annotations.indices.contains(editingTextIndex) {
            if value.isEmpty {
                annotations.remove(at: editingTextIndex)
            } else {
                annotations[editingTextIndex] = .text(
                    value: value,
                    point: textPosition,
                    color: color
                )
            }
        } else if !value.isEmpty {
            annotations.append(.text(value: value, point: textPosition, color: color))
        }

        resetTextEditing()
    }

    private func cancelTextEditing() {
        guard textPosition != nil || editingTextIndex != nil else { return }
        resetTextEditing()
    }

    private func resetTextEditing() {
        textFieldFocused = false
        textPosition = nil
        textValue = ""
        editingTextIndex = nil
    }

    private func textAnnotationIndex(at point: CGPoint, imageRect: CGRect) -> Int? {
        let canvasPoint = map(point, in: imageRect)
        let fontSize = max(14, min(28, imageRect.width / 30))
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)

        for index in annotations.indices.reversed() {
            guard case let .text(value, textPoint, _) = annotations[index] else { continue }
            let mapped = map(textPoint, in: imageRect)
            let textSize = (value as NSString).size(withAttributes: [.font: font])
            let hitRect = CGRect(
                x: mapped.x - 8,
                y: mapped.y - 6,
                width: max(28, textSize.width + 16),
                height: max(28, fontSize + 14)
            )
            if hitRect.contains(canvasPoint) {
                return index
            }
        }
        return nil
    }

    private func undo() {
        if draft != nil {
            draft = nil
        } else {
            _ = annotations.popLast()
        }
    }

    private func applyCrop(_ rect: CGRect) {
        guard let cropped = ScreenshotImageTransform.crop(imageData, normalizedRect: rect) else {
            errorMessage = L("screenshot.error.editor")
            draft = nil
            gestureStart = nil
            return
        }
        imageData = cropped
        annotations.removeAll()
        draft = nil
        gestureStart = nil
    }

    private func rotateImage(clockwise: Bool) {
        guard let rotated = ScreenshotImageTransform.rotate(imageData, clockwise: clockwise) else {
            errorMessage = L("screenshot.error.editor")
            return
        }
        imageData = rotated
        annotations.removeAll()
        draft = nil
    }

    private func normalizedPoint(_ location: CGPoint, in size: CGSize, image: CGImage) -> CGPoint? {
        let rect = imageRect(in: size, image: image)
        guard rect.contains(location) else { return nil }
        return CGPoint(
            x: (location.x - rect.minX) / rect.width,
            y: (location.y - rect.minY) / rect.height
        )
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func imageRect(in size: CGSize, image: CGImage) -> CGRect {
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let displayedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (size.width - displayedSize.width) / 2,
            y: (size.height - displayedSize.height) / 2,
            width: displayedSize.width,
            height: displayedSize.height
        )
    }

    private func draw(
        annotations: [ScreenshotEditorAnnotation],
        draft: ScreenshotEditorDraft?,
        editingTextIndex: Int?,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard let sourceImage else { return }
        let rect = imageRect(in: size, image: sourceImage)
        for (index, annotation) in annotations.enumerated() {
            if index == editingTextIndex { continue }
            draw(annotation, in: &context, imageRect: rect, sourceImage: sourceImage)
        }
        if let draft {
            draw(draft, in: &context, imageRect: rect, sourceImage: sourceImage)
        }
    }

    private func draw(
        _ draft: ScreenshotEditorDraft,
        in context: inout GraphicsContext,
        imageRect: CGRect,
        sourceImage: CGImage
    ) {
        switch draft {
        case let .crop(rect):
            let mapped = map(rect, in: imageRect)
            context.stroke(
                Path(mapped),
                with: .color(.white),
                style: StrokeStyle(lineWidth: 2, dash: [6, 4])
            )
        case let .freehand(points):
            drawPath(points, color: color, lineWidth: lineWidth, in: &context, imageRect: imageRect)
        case let .line(start, end):
            drawArrow(start: start, end: end, color: color, lineWidth: lineWidth, in: &context, imageRect: imageRect)
        case let .rectangle(rect):
            drawShape(rect: rect, color: color, lineWidth: lineWidth, ellipse: false, in: &context, imageRect: imageRect)
        case let .ellipse(rect):
            drawShape(rect: rect, color: color, lineWidth: lineWidth, ellipse: true, in: &context, imageRect: imageRect)
        case let .highlight(rect):
            drawHighlight(rect, color: color, in: &context, imageRect: imageRect)
        case let .mosaic(rect):
            drawMosaicPreview(rect, in: &context, imageRect: imageRect, sourceImage: sourceImage)
        }
    }

    private func draw(
        _ annotation: ScreenshotEditorAnnotation,
        in context: inout GraphicsContext,
        imageRect: CGRect,
        sourceImage: CGImage
    ) {
        switch annotation {
        case let .freehand(points, color, lineWidth):
            drawPath(points, color: color, lineWidth: lineWidth, in: &context, imageRect: imageRect)
        case let .arrow(start, end, color, lineWidth):
            drawArrow(start: start, end: end, color: color, lineWidth: lineWidth, in: &context, imageRect: imageRect)
        case let .rectangle(rect, color, lineWidth):
            drawShape(rect: rect, color: color, lineWidth: lineWidth, ellipse: false, in: &context, imageRect: imageRect)
        case let .ellipse(rect, color, lineWidth):
            drawShape(rect: rect, color: color, lineWidth: lineWidth, ellipse: true, in: &context, imageRect: imageRect)
        case let .highlight(rect, color):
            drawHighlight(rect, color: color, in: &context, imageRect: imageRect)
        case let .mosaic(rect):
            drawMosaicPreview(rect, in: &context, imageRect: imageRect, sourceImage: sourceImage)
        case let .text(value, point, color):
            let mapped = CGPoint(
                x: imageRect.minX + point.x * imageRect.width,
                y: imageRect.minY + point.y * imageRect.height
            )
            context.draw(
                context.resolve(
                    Text(value)
                        .font(.system(size: max(14, min(28, imageRect.width / 30)), weight: .medium))
                        .foregroundStyle(color.swiftUIColor)
                ),
                at: mapped,
                anchor: .topLeading
            )
        }
    }

    private func drawPath(
        _ points: [CGPoint],
        color: ScreenshotEditorColor,
        lineWidth: CGFloat,
        in context: inout GraphicsContext,
        imageRect: CGRect
    ) {
        guard !points.isEmpty else { return }
        var path = Path()
        for (index, point) in points.enumerated() {
            let mapped = map(point, in: imageRect)
            if index == 0 { path.move(to: mapped) } else { path.addLine(to: mapped) }
        }
        context.stroke(
            path,
            with: .color(color.swiftUIColor),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawArrow(
        start: CGPoint,
        end: CGPoint,
        color: ScreenshotEditorColor,
        lineWidth: CGFloat,
        in context: inout GraphicsContext,
        imageRect: CGRect
    ) {
        let startPoint = map(start, in: imageRect)
        let endPoint = map(end, in: imageRect)
        var path = Path()
        path.move(to: startPoint)
        path.addLine(to: endPoint)
        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        let headLength = max(10, lineWidth * 4)
        let left = CGPoint(
            x: endPoint.x - cos(angle - .pi / 6) * headLength,
            y: endPoint.y - sin(angle - .pi / 6) * headLength
        )
        let right = CGPoint(
            x: endPoint.x - cos(angle + .pi / 6) * headLength,
            y: endPoint.y - sin(angle + .pi / 6) * headLength
        )
        path.move(to: left)
        path.addLine(to: endPoint)
        path.addLine(to: right)
        context.stroke(
            path,
            with: .color(color.swiftUIColor),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawShape(
        rect: CGRect,
        color: ScreenshotEditorColor,
        lineWidth: CGFloat,
        ellipse: Bool,
        in context: inout GraphicsContext,
        imageRect: CGRect
    ) {
        let mapped = map(rect, in: imageRect)
        if ellipse {
            context.stroke(Path(ellipseIn: mapped), with: .color(color.swiftUIColor), style: StrokeStyle(lineWidth: lineWidth))
        } else {
            context.stroke(Path(mapped), with: .color(color.swiftUIColor), style: StrokeStyle(lineWidth: lineWidth))
        }
    }

    private func drawHighlight(
        _ rect: CGRect,
        color: ScreenshotEditorColor,
        in context: inout GraphicsContext,
        imageRect: CGRect
    ) {
        context.fill(
            Path(map(rect, in: imageRect)),
            with: .color(color.swiftUIColor.opacity(0.35))
        )
    }

    private func drawMosaicPreview(
        _ rect: CGRect,
        in context: inout GraphicsContext,
        imageRect: CGRect,
        sourceImage: CGImage
    ) {
        let mapped = map(rect, in: imageRect)
        if let pixelated = pixelatedImage(sourceImage, normalizedRect: rect) {
            let image = Image(
                nsImage: NSImage(
                    cgImage: pixelated,
                    size: NSSize(width: pixelated.width, height: pixelated.height)
                )
            )
            context.draw(context.resolve(image), in: mapped)
        } else {
            context.fill(Path(mapped), with: .color(.black.opacity(0.45)))
        }
        context.stroke(Path(mapped), with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1))
    }

    private func map(_ point: CGPoint, in imageRect: CGRect) -> CGPoint {
        CGPoint(
            x: imageRect.minX + point.x * imageRect.width,
            y: imageRect.minY + point.y * imageRect.height
        )
    }

    private func map(_ rect: CGRect, in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + rect.minX * imageRect.width,
            y: imageRect.minY + rect.minY * imageRect.height,
            width: rect.width * imageRect.width,
            height: rect.height * imageRect.height
        )
    }

    private func save() {
        guard let data = renderPNG() else {
            errorMessage = L("screenshot.error.editor")
            return
        }
        do {
            try onSave(data)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recognizeText() {
        guard let sourceImage else { return }
        Task { @MainActor in
            do {
                let text = try await ScreenshotOCRService.recognizeExclusively(sourceImage)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.setString(text, forType: .string) else {
                    throw ScreenshotError.clipboardFailed
                }
                ClipboardHistoryService.shared.refresh()
                errorMessage = L("screenshot.ocr.copied")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func renderPNG() -> Data? {
        guard let sourceImage else { return nil }
        let width = sourceImage.width
        let height = sourceImage.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        for annotation in annotations {
            render(annotation, in: context, sourceImage: sourceImage)
        }

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func render(
        _ annotation: ScreenshotEditorAnnotation,
        in context: CGContext,
        sourceImage: CGImage
    ) {
        let width = CGFloat(sourceImage.width)
        let height = CGFloat(sourceImage.height)
        let lineScale = max(1, width / 900)

        switch annotation {
        case let .freehand(points, color, lineWidth):
            renderPath(points, in: context, width: width, height: height, color: color.nsColor, lineWidth: lineWidth * lineScale)
        case let .arrow(start, end, color, lineWidth):
            renderArrow(start: start, end: end, in: context, width: width, height: height, color: color.nsColor, lineWidth: lineWidth * lineScale)
        case let .rectangle(rect, color, lineWidth):
            renderShape(rect, in: context, width: width, height: height, color: color.nsColor, lineWidth: lineWidth * lineScale, ellipse: false)
        case let .ellipse(rect, color, lineWidth):
            renderShape(rect, in: context, width: width, height: height, color: color.nsColor, lineWidth: lineWidth * lineScale, ellipse: true)
        case let .highlight(rect, color):
            context.setFillColor(color.nsColor.withAlphaComponent(0.35).cgColor)
            context.fill(cgRect(rect, width: width, height: height))
        case let .mosaic(rect):
            renderMosaic(rect, in: context, sourceImage: sourceImage)
        case let .text(value, point, color):
            renderText(value, at: point, in: context, width: width, height: height, color: color.nsColor)
        }
    }

    private func renderPath(
        _ points: [CGPoint],
        in context: CGContext,
        width: CGFloat,
        height: CGFloat,
        color: NSColor,
        lineWidth: CGFloat
    ) {
        guard !points.isEmpty else { return }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginPath()
        for (index, point) in points.enumerated() {
            let mapped = cgPoint(point, width: width, height: height)
            if index == 0 { context.move(to: mapped) } else { context.addLine(to: mapped) }
        }
        context.strokePath()
    }

    private func renderArrow(
        start: CGPoint,
        end: CGPoint,
        in context: CGContext,
        width: CGFloat,
        height: CGFloat,
        color: NSColor,
        lineWidth: CGFloat
    ) {
        let startPoint = cgPoint(start, width: width, height: height)
        let endPoint = cgPoint(end, width: width, height: height)
        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        let headLength = max(12, lineWidth * 4)
        let left = CGPoint(x: endPoint.x - cos(angle - .pi / 6) * headLength, y: endPoint.y - sin(angle - .pi / 6) * headLength)
        let right = CGPoint(x: endPoint.x - cos(angle + .pi / 6) * headLength, y: endPoint.y - sin(angle + .pi / 6) * headLength)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginPath()
        context.move(to: startPoint)
        context.addLine(to: endPoint)
        context.move(to: left)
        context.addLine(to: endPoint)
        context.addLine(to: right)
        context.strokePath()
    }

    private func renderShape(
        _ rect: CGRect,
        in context: CGContext,
        width: CGFloat,
        height: CGFloat,
        color: NSColor,
        lineWidth: CGFloat,
        ellipse: Bool
    ) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        if ellipse {
            context.strokeEllipse(in: cgRect(rect, width: width, height: height))
        } else {
            context.stroke(cgRect(rect, width: width, height: height))
        }
    }

    private func renderMosaic(
        _ rect: CGRect,
        in context: CGContext,
        sourceImage: CGImage
    ) {
        let width = CGFloat(sourceImage.width)
        let target = cgRect(rect, width: width, height: CGFloat(sourceImage.height))
        guard let mosaic = pixelatedImage(sourceImage, normalizedRect: rect) else { return }
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(mosaic, in: target)
        context.restoreGState()
    }

    /// 使用 Snapzy 同样的 Core Image `CIPixellate` 处理截图选区。
    /// 标注坐标以预览左上角为原点，裁剪到 CGImage 时只在这里翻转一次 Y。
    private func pixelatedImage(
        _ sourceImage: CGImage,
        normalizedRect rect: CGRect,
        blockSize: CGFloat = 12
    ) -> CGImage? {
        let target = cgRect(
            rect,
            width: CGFloat(sourceImage.width),
            height: CGFloat(sourceImage.height)
        )
        guard target.width >= 2,
              target.height >= 2,
              let crop = sourceImage.cropping(to: target) else {
            return nil
        }

        let input = CIImage(cgImage: crop)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(max(4, blockSize), forKey: kCIInputScaleKey)
        filter.setValue(
            CIVector(x: input.extent.midX, y: input.extent.midY),
            forKey: kCIInputCenterKey
        )
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }

    private func renderText(
        _ value: String,
        at point: CGPoint,
        in context: CGContext,
        width: CGFloat,
        height: CGFloat,
        color: NSColor
    ) {
        let fontSize = max(16, min(42, width / 30))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
        let origin = cgPoint(point, width: width, height: height)
        context.saveGState()
        context.textPosition = CGPoint(x: origin.x, y: origin.y - fontSize)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func cgPoint(_ point: CGPoint, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: point.x * width, y: (1 - point.y) * height)
    }

    private func cgRect(_ rect: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX * width,
            y: (1 - rect.maxY) * height,
            width: rect.width * width,
            height: rect.height * height
        )
    }
}
