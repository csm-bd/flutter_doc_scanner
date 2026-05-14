import AVFoundation
import UIKit
import Vision
import CoreImage

@available(iOS 13.0, *)
final class AutoScanViewController: UIViewController, AVCapturePhotoCaptureDelegate {
    
    // New variables for limiting pages
    var pageLimit: Int = 1
    private var currentScanCount: Int = 0

    var onImageCaptured: ((UIImage) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?

    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.flutter_doc_scanner.autoscan.session")
    private let processingQueue = DispatchQueue(label: "com.flutter_doc_scanner.autoscan.processing")
    private let photoOutput = AVCapturePhotoOutput()
    private let ciContext = CIContext()

    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasConfiguredSession = false
    private var isCapturingPhoto = false

    private lazy var cancelButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Cancel", for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        button.layer.cornerRadius = 18
        button.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private lazy var captureButton: UIButton = {
        let button = UIButton(type: .custom)
        button.backgroundColor = .white
        button.layer.cornerRadius = 34
        button.layer.borderWidth = 4
        button.layer.borderColor = UIColor.black.withAlphaComponent(0.20).cgColor
        button.addTarget(self, action: #selector(captureTapped), for: .touchDown)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(cancelButton)
        view.addSubview(captureButton)

        NSLayoutConstraint.activate([
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            captureButton.widthAnchor.constraint(equalToConstant: 68),
            captureButton.heightAnchor.constraint(equalToConstant: 68)
        ])
    }

    @objc private func captureTapped() {
        guard !isCapturingPhoto else { return }
        
        // Check if we already hit the limit
        if currentScanCount >= pageLimit {
            return 
        }

        isCapturingPhoto = true
        capturePhoto()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            failAndDismiss(error)
            return
        }

        guard let imageData = photo.fileDataRepresentation(), let image = UIImage(data: imageData) else {
            return
        }

        currentScanCount += 1

        // If we reached the limit, dismiss and return the result
        if currentScanCount >= pageLimit {
            dismissScanner(animated: true) { [weak self] in
                self?.processAndDeliverCapturedImage(image)
            }
        } else {
            // Otherwise, allow another capture
            isCapturingPhoto = false
            // Optional: You could show a "Page 1 captured" toast here
        }
    }

    // ... Keep all your existing image processing methods (prepareSingleImage, detectAndCropDocument, etc.) exactly as they were ...
    
    private func processAndDeliverCapturedImage(_ image: UIImage) {
        processingQueue.async { [self] in
            let processedImage = prepareSingleImage(image, maxDimension: 1280)
            DispatchQueue.main.async {
                self.onImageCaptured?(processedImage)
            }
        }
    }

    private func prepareSingleImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let normalizedImage = normalizedUprightImage(image)
        let detectionInput = resizedImageIfNeeded(normalizedImage, maxDimension: 1600)
        let croppedImage = detectAndCropDocument(detectionInput) ?? detectionInput
        let portraitImage = forcePortraitOrientation(croppedImage)
        return resizedImageIfNeeded(portraitImage, maxDimension: maxDimension)
    }

    private func normalizedUprightImage(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
    }

    private func forcePortraitOrientation(_ image: UIImage) -> UIImage {
        guard image.size.width > image.size.height else { return image }
        let targetSize = CGSize(width: image.size.height, height: image.size.width)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            let context = UIGraphicsGetCurrentContext()
            context?.translateBy(x: targetSize.width / 2, y: targetSize.height / 2)
            context?.rotate(by: -.pi / 2)
            image.draw(in: CGRect(x: -image.size.width/2, y: -image.size.height/2, width: image.size.width, height: image.size.height))
        }
    }

    private func resizedImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let currentMax = max(image.size.width, image.size.height)
        guard currentMax > maxDimension else { return image }
        let scale = maxDimension / currentMax
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: targetSize)) }
    }

    private func detectAndCropDocument(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.7
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        try? handler.perform([request])
        guard let observation = (request.results as? [VNRectangleObservation])?.first else { return nil }
        let extent = ciImage.extent
        func denormalize(_ point: CGPoint) -> CGPoint {
            CGPoint(x: extent.origin.x + point.x * extent.width, y: extent.origin.y + point.y * extent.height)
        }
        let perspectiveFilter = CIFilter(name: "CIPerspectiveCorrection")
        perspectiveFilter?.setValue(ciImage, forKey: kCIInputImageKey)
        perspectiveFilter?.setValue(CIVector(cgPoint: denormalize(observation.topLeft)), forKey: "inputTopLeft")
        perspectiveFilter?.setValue(CIVector(cgPoint: denormalize(observation.topRight)), forKey: "inputTopRight")
        perspectiveFilter?.setValue(CIVector(cgPoint: denormalize(observation.bottomRight)), forKey: "inputBottomRight")
        perspectiveFilter?.setValue(CIVector(cgPoint: denormalize(observation.bottomLeft)), forKey: "inputBottomLeft")
        if let outputImage = perspectiveFilter?.outputImage, let outputCGImage = ciContext.createCGImage(outputImage, from: outputImage.extent) {
            return UIImage(cgImage: outputCGImage)
        }
        return nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startScannerIfNeeded()
    }

    private func startScannerIfNeeded() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            configureAndStartSession()
        } else {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { DispatchQueue.main.async { self?.configureAndStartSession() } }
            }
        }
    }

    private func configureAndStartSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.captureSession.beginConfiguration()
            if let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: camera) {
                if self.captureSession.canAddInput(input) { self.captureSession.addInput(input) }
                if self.captureSession.canAddOutput(self.photoOutput) { self.captureSession.addOutput(self.photoOutput) }
            }
            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()
            DispatchQueue.main.async {
                let preview = AVCaptureVideoPreviewLayer(session: self.captureSession)
                preview.videoGravity = .resizeAspectFill
                preview.frame = self.view.bounds
                self.view.layer.insertSublayer(preview, at: 0)
                self.previewLayer = preview
            }
        }
    }

    private func capturePhoto() {
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func dismissScanner(animated: Bool, completion: @escaping () -> Void) {
        sessionQueue.async { self.captureSession.stopRunning() }
        dismiss(animated: animated, completion: completion)
    }

    @objc private func cancelTapped() {
        dismissScanner(animated: true) { self.onCancel?() }
    }
    
    private func failAndDismiss(_ error: Error) {
        dismissScanner(animated: true) { self.onError?(error) }
    }
}