#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// Minimal photo capture sheet. Deliberately NOT UIImagePickerController:
/// the picker reconfigures the shared AVAudioSession, which would
/// interrupt a live recording; this capture session is told to leave the
/// audio session alone, so snapping a slide can't pause the mic.
struct CameraCaptureView: View {
    let onCapture: @MainActor (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var camera = CameraModel()
    @State private var cameraProblem: CameraProblem?
    @State private var cameraReady = false
    @State private var isCapturing = false
    @State private var captureFailed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let cameraProblem {
                ContentUnavailableView(
                    cameraProblem.title,
                    systemImage: "camera",
                    description: Text(cameraProblem.message))
                .foregroundStyle(.white)
            } else {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                if !cameraReady {
                    ProgressView("Starting camera...")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            VStack {
                HStack {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                        .padding()
                    Spacer()
                }
                Spacer()
                Button {
                    isCapturing = true
                    camera.capture()
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(.white, lineWidth: 4)
                            .frame(width: 72, height: 72)
                            .background(Circle().fill(.white.opacity(0.25)))
                        if isCapturing {
                            ProgressView()
                                .tint(.white)
                        }
                    }
                }
                .disabled(cameraProblem != nil || !cameraReady || isCapturing)
                .padding(.bottom, 28)
            }
        }
        .task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                cameraProblem = .denied
                return
            }
            camera.onCapture = { image in
                Task { @MainActor in
                    isCapturing = false
                    guard let image else {
                        captureFailed = true
                        return
                    }
                    onCapture(image)
                    dismiss()
                }
            }
            camera.start { ready in
                Task { @MainActor in
                    cameraReady = ready
                    if !ready { cameraProblem = .unavailable }
                }
            }
        }
        .onDisappear { camera.stop() }
        .alert("Photo wasn't captured", isPresented: $captureFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Keep the camera open and try again.")
        }
    }
}

private enum CameraProblem {
    case denied
    case unavailable

    var title: LocalizedStringKey {
        switch self {
        case .denied: "Camera access needed"
        case .unavailable: "Camera unavailable"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .denied: "Enable the camera for Loqi in Settings."
        case .unavailable: "No usable camera was found on this device."
        }
    }
}

/// Session + photo output on a private queue. @unchecked Sendable: all
/// mutable state is confined to `queue`.
private final class CameraModel: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.kunzhipeng.loqi.camera")
    private var configured = false
    var onCapture: (@Sendable (UIImage?) -> Void)?

    func start(_ completion: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                // The whole point of this view: leave the recording's
                // audio session untouched.
                self.session.automaticallyConfiguresApplicationAudioSession = false
                if let device = AVCaptureDevice.default(for: .video),
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.session.canAddInput(input),
                   self.session.canAddOutput(self.output) {
                    self.session.addInput(input)
                    self.session.addOutput(self.output)
                    self.configured = true
                }
                self.session.commitConfiguration()
            }
            guard self.configured else {
                completion(false)
                return
            }
            if !self.session.isRunning { self.session.startRunning() }
            completion(self.session.isRunning)
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func capture() {
        queue.async {
            guard self.configured, self.session.isRunning else {
                self.onCapture?(nil)
                return
            }
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil else {
            onCapture?(nil)
            return
        }
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        onCapture?(image)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
#endif
