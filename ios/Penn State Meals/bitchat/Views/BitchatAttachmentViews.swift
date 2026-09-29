import QuickLook
import SwiftUI

struct PreviewAttachmentItem: Identifiable {
    let attachment: BitchatAttachment
    var id: String { attachment.localPath }
}

struct MessageDetailsItem: Identifiable {
    let id = UUID()
    let sender: String
    let timestamp: Date
    let deliveryText: String
    let routingText: String
    let attachmentName: String?
}

struct MessageDetailsSheet: View {
    let item: MessageDetailsItem

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("From", value: item.sender)
                LabeledContent("Time", value: item.timestamp.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Delivery", value: item.deliveryText)
                LabeledContent("Route", value: item.routingText)
                if let attachmentName = item.attachmentName {
                    LabeledContent("Attachment", value: attachmentName)
                }
            }
            .navigationTitle("Message Details")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct AttachmentQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

struct DeliveryStatusView: View {
    let status: DeliveryStatus

    private var label: String {
        switch status {
        case .sending: "Sending…"
        case .sent: "Sent"
        case .delivered: "Delivered"
        case .read: "Read"
        case .failed: "Not Delivered"
        case .partiallyDelivered(let reached, let total): "Delivered to \(reached) of \(total)"
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(isFailed ? Color.red : Color.secondary)
            .accessibilityLabel(accessibilityDescription)
            .help(accessibilityDescription)
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private var accessibilityDescription: String {
        switch status {
        case .failed(let reason): "Not delivered: \(reason)"
        case .delivered(let nickname, _): "Delivered to \(nickname)"
        case .read(let nickname, _): "Read by \(nickname)"
        default: label
        }
    }
}

// The transcript and composer stay in SwiftUI. This overlay only owns the throw's layers.
struct PendingChatThrow {
    let message: BitchatMessage
    let sourceFrame: CGRect
    let sourceText: UIImage
    let sourceTextOrigin: CGPoint
}

struct ChatThrowRequest {
    let id: String
    let source: CGRect
    let target: CGRect
    let sourceText: UIImage
    let targetText: UIImage
    let sourceTextOrigin: CGPoint
}

@MainActor
struct ChatThrowOverlay: UIViewRepresentable {
    let request: ChatThrowRequest?
    let composerCapture: ChatComposerCapture
    let completion: (String) -> Void

    func makeUIView(context: Context) -> ChatThrowAnimationView {
        ChatThrowAnimationView()
    }

    func updateUIView(_ view: ChatThrowAnimationView, context: Context) {
        composerCapture.view = view
        view.update(request, completion: completion)
    }

    static func dismantleUIView(_ view: ChatThrowAnimationView, coordinator: ()) {
        view.cancel()
    }
}

@MainActor
final class ChatThrowAnimationView: UIView, @preconcurrency CAAnimationDelegate {
    private var requestID: String?
    private var flight: UIView?
    private var initialTarget: CGRect = .zero
    private var currentTarget: CGRect = .zero
    private var flightEndsAt: CFTimeInterval = 0
    private var completion: ((String) -> Void)?
    private var flightDuration: TimeInterval = 0

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        accessibilityElementsHidden = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func cancel() {
        completion = nil
        requestID = nil
        flight?.removeFromSuperview()
        flight = nil
    }

    func update(_ request: ChatThrowRequest?, completion: @escaping (String) -> Void) {
        guard let request else { cancel(); return }
        if requestID == request.id {
            retarget(to: request.target)
            return
        }
        cancel()
        requestID = request.id
        self.completion = completion
        flightEndsAt = 0
        initialTarget = request.target
        currentTarget = request.target
        let flight = UIView(frame: bounds)
        flight.isUserInteractionEnabled = false
        addSubview(flight)
        self.flight = flight

        let bubble = UIView(frame: request.target)
        bubble.backgroundColor = .systemBlue
        bubble.layer.cornerRadius = 17.5
        bubble.layer.cornerCurve = .continuous
        bubble.clipsToBounds = true
        bubble.layer.anchorPoint = CGPoint(x: 1, y: 0.5)
        bubble.layer.position = CGPoint(x: request.target.maxX, y: request.target.midY)
        flight.addSubview(bubble)

        // Freeze both endpoints. Neither image's bounds changes as the blue shell shrinks.
        let source = UIImageView(image: request.sourceText)
        let target = UIImageView(image: request.targetText)
        for text in [source, target] {
            text.frame.origin = CGPoint(x: 14, y: 6)
            bubble.addSubview(text)
        }
        source.alpha = 0
        target.alpha = 1

        // Relative child times start when Core Animation commits the transaction,
        // not while SwiftUI is still laying out the transcript.
        var bubbleAnimations: [CAAnimation] = []
        let timing = CAMediaTimingFunction(controlPoints: 0.20, 0, 0.18, 1)
        let bounds = CABasicAnimation(keyPath: "bounds.size")
        bounds.fromValue = NSValue(cgSize: request.source.size)
        bounds.toValue = NSValue(cgSize: request.target.size)
        bounds.duration = 0.4
        bounds.timingFunction = timing
        bubbleAnimations.append(bounds)

        let radius = CABasicAnimation(keyPath: "cornerRadius")
        radius.fromValue = 20
        radius.toValue = 17.5
        radius.duration = 0.4
        radius.timingFunction = timing
        bubbleAnimations.append(radius)

        var duration: TimeInterval = 0.4
        for (axis, start, end, delay) in [
            ("x", request.source.maxX, request.target.maxX, 0.0),
            ("y", request.source.midY, request.target.midY, 0.055)
        ] {
            // Match the reference's separate horizontal and delayed vertical springs.
            let spring = CASpringAnimation(keyPath: "position.\(axis)")
            spring.mass = 1
            spring.stiffness = 141.759
            spring.damping = 17.3503
            spring.fromValue = start
            spring.toValue = end
            spring.duration = spring.settlingDuration
            duration = max(duration, delay + spring.duration)
            spring.beginTime = delay
            bubbleAnimations.append(spring)
        }

        for (text, isSource) in [(source, true), (target, false)] {
            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = NSValue(cgPoint: CGPoint(x: request.sourceTextOrigin.x + text.bounds.width / 2,
                                                          y: request.sourceTextOrigin.y + text.bounds.height / 2))
            position.toValue = NSValue(cgPoint: text.layer.position)
            position.duration = 0.4
            position.timingFunction = timing

            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = isSource ? 1 : 0
            opacity.toValue = isSource ? 0 : 1
            opacity.duration = 0.16
            opacity.beginTime = 0.04
            installGroup([position, opacity], on: text.layer, duration: duration)
        }
        flightDuration = duration
        installGroup(bubbleAnimations, on: bubble.layer, duration: duration, messageID: request.id)
    }

    func animationDidStart(_ anim: CAAnimation) {
        guard anim.value(forKey: "messageID") as? String == requestID else { return }
        flightEndsAt = CACurrentMediaTime() + flightDuration
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag, let id = anim.value(forKey: "messageID") as? String, id == requestID else { return }
        // Hand the visible bubble back only after the render server finishes the flight.
        let callback = completion
        Task { @MainActor [weak self] in
            guard self?.requestID == id else { return }
            callback?(id)
        }
    }

    private func retarget(to target: CGRect) {
        guard currentTarget != target, let flight else { return }
        currentTarget = target
        let translation = CATransform3DMakeTranslation(
            target.maxX - initialTarget.maxX, target.midY - initialTarget.midY, 0
        )
        let current = flight.layer.presentation()?.transform ?? flight.layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flight.layer.transform = translation
        CATransaction.commit()
        let remaining = flightEndsAt == 0 ? flightDuration : flightEndsAt - CACurrentMediaTime()
        guard remaining > 0 else { return }
        // Move the flight's container from its presentation position without restarting its springs.
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: current)
        animation.toValue = NSValue(caTransform3D: translation)
        animation.duration = min(0.16, remaining)
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flight.layer.add(animation, forKey: "throw.retarget")
    }

    private func installGroup(_ animations: [CAAnimation], on layer: CALayer, duration: TimeInterval, messageID: String? = nil) {
        for animation in animations {
            animation.fillMode = .both
            animation.isRemovedOnCompletion = false
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        group.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        if let messageID {
            group.setValue(messageID, forKey: "messageID")
            group.delegate = self
        }
        layer.add(group, forKey: "throw")
    }
}


/// Captures the live editor through the existing animation overlay; no second editor or text layout.
@MainActor
final class ChatComposerCapture {
    weak var view: ChatThrowAnimationView?
    private weak var cachedEditor: UIView?

    func capture(text: String, frame: CGRect) -> (image: UIImage, origin: CGPoint)? {
        guard let view, let window = view.window else { return nil }
        func findEditor(in candidate: UIView) -> UIView? {
            guard !candidate.isHidden, candidate.alpha > 0 else { return nil }
            let matches: Bool
            if let editor = candidate as? UITextView {
                matches = editor.text == text
            } else if let editor = candidate as? UITextField {
                matches = editor.text == text
            } else {
                matches = false
            }
            if matches, candidate.convert(candidate.bounds, to: view).intersects(frame) {
                return candidate
            }
            for child in candidate.subviews {
                if let editor = findEditor(in: child) { return editor }
            }
            return nil
        }
        let editor: UIView?
        if let cachedEditor, cachedEditor.window === window,
           cachedEditor.convert(cachedEditor.bounds, to: view).intersects(frame),
           ((cachedEditor as? UITextView)?.text == text || (cachedEditor as? UITextField)?.text == text) {
            editor = cachedEditor
        } else {
            editor = findEditor(in: window)
        }
        guard let editor else { return nil }
        cachedEditor = editor
        let editorFrame = editor.convert(editor.bounds, to: view)
        // Capture already-rendered glyphs: no text-color mutation, text relayout, or synchronous screen flush.
        let format = UIGraphicsImageRendererFormat()
        format.scale = editor.traitCollection.displayScale
        let bounds = CGRect(origin: .zero, size: editor.bounds.size)
        var captured = false
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            if let background = editor.layer.backgroundColor, background.alpha > 0 {
                // Keep an opaque UIKit editor background out of the glyph mask without a screen flush.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                editor.layer.backgroundColor = nil
                editor.layer.render(in: context.cgContext)
                editor.layer.backgroundColor = background
                CATransaction.commit()
                captured = true
            } else {
                captured = editor.drawHierarchy(in: bounds, afterScreenUpdates: false)
            }
        }
        guard captured else { return nil }
        return (image.withTintColor(.white, renderingMode: .alwaysOriginal),
                CGPoint(x: editorFrame.minX - frame.minX, y: editorFrame.minY - frame.minY))
    }
}
