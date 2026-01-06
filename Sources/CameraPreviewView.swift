import AVFoundation
import SwiftUI

/// NSView wrapper for AVCaptureVideoPreviewLayer.
/// Displays a live camera feed from the provided capture session.
/// Re-enables mouse events for this view even when the parent window ignores them.
final class CameraPreviewNSView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    
    var session: AVCaptureSession? {
        get { previewLayer?.session }
        set {
            previewLayer?.session = newValue
        }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }
    
    private func setupLayer() {
        wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer()
        layer.videoGravity = .resizeAspectFill
        // Mirror horizontally for front-facing camera (feels more natural)
        layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        self.layer = layer
        self.previewLayer = layer
    }
    
    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
    
    /// Completely disconnects and removes the preview layer.
    /// Must be called before the capture session is stopped/deallocated.
    func tearDown() {
        previewLayer?.session = nil
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
        layer = CALayer()  // Replace with empty layer
    }
    
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            tearDown()
        }
    }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// Wrapper class that can be invalidated to disconnect from the session.
/// This allows the controller to force disconnection before window teardown.
@MainActor
final class SessionHolder {
    weak var session: AVCaptureSession?
    var isInvalidated = false
    private var registeredViews: [WeakViewRef] = []
    
    private class WeakViewRef {
        weak var view: CameraPreviewNSView?
        init(_ view: CameraPreviewNSView) { self.view = view }
    }
    
    init(session: AVCaptureSession) {
        self.session = session
    }
    
    func registerView(_ view: CameraPreviewNSView) {
        registeredViews.append(WeakViewRef(view))
    }
    
    func invalidate() {
        isInvalidated = true
        session = nil
        // Explicitly tear down all registered views
        for ref in registeredViews {
            ref.view?.tearDown()
        }
        registeredViews.removeAll()
    }
}

/// SwiftUI wrapper for the camera preview NSView.
struct CameraPreviewLayerView: NSViewRepresentable {
    let sessionHolder: SessionHolder
    
    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.session = sessionHolder.session
        sessionHolder.registerView(view)
        return view
    }
    
    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        // Disconnect if invalidated
        if sessionHolder.isInvalidated {
            nsView.tearDown()
            return
        }
        // Only update if session is still running to avoid reconnecting to stopped session
        if let session = sessionHolder.session, session.isRunning {
            nsView.session = session
        }
    }
    
    static func dismantleNSView(_ nsView: CameraPreviewNSView, coordinator: ()) {
        nsView.tearDown()
    }
}

/// Live camera preview with optional circle clipping.
/// Used in the draggable overlay window during recording.
struct CameraPreviewView: View {
    let sessionHolder: SessionHolder
    let size: CGFloat
    let shape: AppSettings.CameraOverlayShape
    
    var body: some View {
        CameraPreviewLayerView(sessionHolder: sessionHolder)
            .frame(width: size, height: size)
            .modifier(ShapeClipModifier(shape: shape))
    }
}

/// Applies the appropriate clip shape based on overlay shape setting.
private struct ShapeClipModifier: ViewModifier {
    let shape: AppSettings.CameraOverlayShape
    
    func body(content: Content) -> some View {
        switch shape {
        case .circle:
            content.clipShape(Circle())
        case .rectangle:
            content.clipShape(Rectangle())
        }
    }
}
