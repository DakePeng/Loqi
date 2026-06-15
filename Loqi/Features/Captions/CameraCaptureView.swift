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
    @State private var denied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if denied {
                ContentUnavailableView(
                    "Camera access needed",
                    systemImage: "camera",
                    description: Text("Enable the camera for Loqi in Settings."))
                .foregroundStyle(.white)
            } else {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
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
                    camera.capture()
                } label: {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(.white.opacity(0.25)))
                }
                .disabled(denied)
                .padding(.bottom, 28)
            }
        }
        .task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                denied = true
                return
            }
            camera.onCapture = { image in
                Task { @MainActor in
                    if let image { onCapture(image) }
                    dismiss()
                }
            }
            camera.start()
        }
        .onDisappear { camera.stop() }
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

    func start() {
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
            if self.configured { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
    }

    func capture() {
        queue.async {
            guard self.configured else { return }
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
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
