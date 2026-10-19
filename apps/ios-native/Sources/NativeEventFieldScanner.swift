import SwiftUI
import AVFoundation
import UIKit

struct NativeEventQRScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> NativeEventCameraController {
        let controller = NativeEventCameraController(); controller.onScan = onScan; controller.onError = onError; return controller
    }
    func updateUIViewController(_ uiViewController: NativeEventCameraController, context: Context) {}
    static func dismantleUIViewController(_ controller: NativeEventCameraController, coordinator: ()) { controller.stop() }
}

final class NativeEventCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let capture = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var lastScan = Date.distantPast
    private var active = true
    private let captureQueue = DispatchQueue(label: "kr.jaegun.event-qr")
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in DispatchQueue.main.async { guard let self, self.active else { return }; if allowed { self.configure() } else { self.onError?("카메라 권한이 거부되었습니다. 설정에서 허용한 후 다시 시도하세요.") } } }
        default: onError?("카메라 권한이 없습니다. 설정에서 허용한 후 다시 시도하세요.")
        }
    }
    private func configure() {
        guard active else { return }
        do {
            guard let device = AVCaptureDevice.default(for: .video) else { throw NativeAPIError.security("카메라를 사용할 수 없습니다.") }
            let input = try AVCaptureDeviceInput(device: device), output = AVCaptureMetadataOutput()
            guard capture.canAddInput(input), capture.canAddOutput(output) else { throw NativeAPIError.security("QR 카메라를 시작하지 못했습니다.") }
            capture.beginConfiguration(); capture.addInput(input); capture.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            guard output.availableMetadataObjectTypes.contains(.qr) else { capture.commitConfiguration(); throw NativeAPIError.security("QR 인식을 지원하지 않는 카메라입니다.") }
            output.metadataObjectTypes = [.qr]; capture.commitConfiguration()
            let layer = AVCaptureVideoPreviewLayer(session: capture); layer.videoGravity = .resizeAspectFill; layer.frame = view.bounds
            view.layer.addSublayer(layer); preview = layer
            let session = capture; captureQueue.async { session.startRunning() }
        } catch { onError?(error.localizedDescription) }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard active, Date().timeIntervalSince(lastScan) >= 3,
              let token = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        lastScan = Date()
        guard token.range(of: "^jg3\\.[a-f0-9]{48}$", options: .regularExpression) != nil else { onError?("이 앱의 행사 명찰 QR이 아닙니다."); return }
        onScan?(token)
    }
    func stop() { active = false; let session = capture; captureQueue.async { session.stopRunning() } }
}
