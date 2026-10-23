import AVFoundation
import SwiftUI
import PhotosUI
import Vision

/// 二维码内容解析 —— 逐字节对照 Android 的 `QrScanActivity.parseSnCode`。
///
/// 设备上的二维码形如 `KLCXKJ-Water,M,AABBCCDDEEFF`：
/// 取**最后一个逗号字段**，去掉冒号、转大写，必须是 12 位十六进制。
///
/// ⚠️ 不能「随便捞一段 12 位 hex」：二维码里可能还有别的编号，
/// 捞错了会去开别人房间的表。
enum QrCodeParser {

    static let devicePrefix = "KLCXKJ-Water"

    static func parseSnCode(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard let last = parts.last else { return nil }
        let normalized = last
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
            .uppercased()
        guard normalized.count == 12 else { return nil }
        let hexSet = CharacterSet(charactersIn: "0123456789ABCDEF")
        guard normalized.unicodeScalars.allSatisfy({ hexSet.contains($0) }) else { return nil }
        return normalized
    }
}

/// 扫码页。
///
/// 配色**故意写死**（纯黑遮罩、白色控件）——它永远压在相机画面上，
/// 不参与深浅模式，强调色也不跟自定义背景走（万一提取出深色就看不见了）。
/// 微信/支付宝的扫码页都是这个路子（Android 注释里也是这么说的）。
struct QrScanView: View {
    let onResult: (String) -> Void
    let onCancel: () -> Void

    @State private var errorText: String?
    @State private var handled = false
    @State private var torch = false
    @State private var photo: PhotosPickerItem?
    @State private var readingPhoto = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(
                torch: torch,
                onCode: accept,
                onError: { msg in
                    errorText = msg
                }
            )
            .ignoresSafeArea()

            // 取景框
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height) * 0.66
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 3)
                    .frame(width: side, height: side)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.16))
                            .clipShape(Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                HStack(spacing: 32) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("从相册选择", systemImage: "photo")
                    }.disabled(readingPhoto)
                    if AVCaptureDevice.default(for: .video)?.hasTorch == true {
                        Button { torch.toggle() } label: {
                            Label(torch ? "关闭手电筒" : "打开手电筒", systemImage: torch ? "flashlight.on.fill" : "flashlight.off.fill")
                        }
                    }
                }.foregroundStyle(.white).padding(.bottom, 20).buttonStyle(InstantButtonStyle())

                VStack(spacing: 8) {
                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0xFFD166))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                            Button("去设置") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                    } else {
                        Text("对准热水器上的二维码")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                        Text("也可以直接从「附近设备」里选，不用扫码")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.bottom, 48)
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { torch = false }
        .task(id: photo) {
            guard let photo else { return }
            readingPhoto = true
            defer { readingPhoto = false }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                let values = try await Task.detached(priority: .userInitiated) {
                    let request = VNDetectBarcodesRequest()
                    request.symbologies = [.qr]
                    try VNImageRequestHandler(data: data).perform([request])
                    return (request.results ?? []).compactMap(\.payloadStringValue)
                }.value
                guard !Task.isCancelled else { return }
                if let value = values.first(where: { QrCodeParser.parseSnCode($0) != nil }) { accept(value) }
                else { errorText = "未识别到设备二维码" }
            } catch { if !Task.isCancelled { errorText = "图片识别失败，请重试" } }
        }
    }

    private func accept(_ raw: String) {
        guard !handled else { return }
        guard let sn = QrCodeParser.parseSnCode(raw) else { errorText = "未识别到设备二维码"; return }
        handled = true
        torch = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onResult(sn)
    }
}

/// AVFoundation 相机预览 + 二维码识别
private struct CameraPreview: UIViewRepresentable {
    let torch: Bool
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onError: onError)
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.backgroundColor = .black
        context.coordinator.start(in: v)
        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) { context.coordinator.setTorch(torch) }

    static func dismantleUIView(_ uiView: PreviewUIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class PreviewUIView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "linyu.qr.session")
        private let onCode: (String) -> Void
        private let onError: (String) -> Void
        private var lastCode: String = ""
        private var stopped = false
        private var device: AVCaptureDevice?

        init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onCode = onCode
            self.onError = onError
        }

        func start(in view: PreviewUIView) {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configure(in: view)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        if granted {
                            self.configure(in: view)
                        } else {
                            self.onError("没有相机权限。请到「设置 → 淋浴」里允许相机，或直接从附近设备里选。")
                        }
                    }
                }
            default:
                onError("没有相机权限。请到「设置 → 淋浴」里允许相机，或直接从附近设备里选。")
            }
        }

        private func configure(in view: PreviewUIView) {
            guard !stopped else { return }
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                onError("相机无法启动（可能被其他 App 占用）")
                return
            }

            session.beginConfiguration()
            self.device = device
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                // 只认二维码：设备标签上是 QR，不需要条形码/一维码
                if output.availableMetadataObjectTypes.contains(.qr) {
                    output.metadataObjectTypes = [.qr]
                }
            }
            session.commitConfiguration()

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            view.previewLayer = layer
            layer.frame = view.bounds

            queue.async {
                if !self.session.isRunning { self.session.startRunning() }
            }
        }

        func stop() {
            stopped = true
            setTorch(false)
            queue.async {
                if self.session.isRunning { self.session.stopRunning() }
            }
        }

        func setTorch(_ enabled: Bool) {
            guard let device, device.hasTorch else { return }
            queue.async {
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    if device.isTorchModeSupported(enabled ? .on : .off) { device.torchMode = enabled ? .on : .off }
                } catch { DispatchQueue.main.async { self.onError("手电筒无法开启") } }
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue else { return }
            // 同一个码会连续回调很多次，只处理第一次
            guard value != lastCode else { return }
            lastCode = value
            onCode(value)
        }
    }
}
