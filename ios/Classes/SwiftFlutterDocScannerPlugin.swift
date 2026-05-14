import Flutter
import UIKit
import Vision
import VisionKit
import PDFKit

@available(iOS 13.0, *)
public class SwiftFlutterDocScannerPlugin: NSObject, FlutterPlugin, VNDocumentCameraViewControllerDelegate {
   var resultChannel: FlutterResult?
   var presentingController: UIViewController? // Changed to UIViewController to support both types
   var currentMethod: String?

   public static func register(with registrar: FlutterPluginRegistrar) {
       let channel = FlutterMethodChannel(name: "flutter_doc_scanner", binaryMessenger: registrar.messenger())
       let instance = SwiftFlutterDocScannerPlugin()
       registrar.addMethodCallDelegate(instance, channel: channel)
   }

   public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
       self.resultChannel = result
       self.currentMethod = call.method
       let presentedVC: UIViewController? = UIApplication.shared.keyWindow?.rootViewController

       if call.method == "getScanDocuments" || call.method == "getScannedDocumentAsPdf" {
           let scanner = VNDocumentCameraViewController()
           scanner.delegate = self
           self.presentingController = scanner
           presentedVC?.present(scanner, animated: true)
       } else if call.method == "getScannedDocumentAsImages" {
           let arguments = call.arguments as? [String: Any]
           let useAutomaticSinglePictureProcessing = (arguments?["useAutomaticSinglePictureProcessing"] as? Bool) ?? false
           let limit = (arguments?["limit"] as? Int) ?? 1 

           if useAutomaticSinglePictureProcessing {
               let controller = AutoScanViewController()
               controller.modalPresentationStyle = .fullScreen
               controller.pageLimit = limit // Pass the limit
               
               controller.onImageCaptured = { [weak self] image in
                   // This is still called for the last image to maintain plugin flow
                   guard let self = self else { return }
                   self.handleFinalCapture(image: image)
               }
               controller.onCancel = { [weak self] in
                   self?.resultChannel?(nil)
               }
               controller.onError = { [weak self] error in
                   self?.resultChannel?(FlutterError(code: "SCAN_ERROR", message: "Failed to scan", details: error.localizedDescription))
               }
               self.presentingController = controller
               presentedVC?.present(controller, animated: true)
           } else {
               let scanner = VNDocumentCameraViewController()
               scanner.delegate = self
               self.presentingController = scanner
               presentedVC?.present(scanner, animated: true)
           }
       } else {
           result(FlutterMethodNotImplemented)
       }
   }

   private func handleFinalCapture(image: UIImage) {
       DispatchQueue.global(qos: .userInitiated).async {
           do {
               let path = try self.saveSingleImage(image: image)
               DispatchQueue.main.async {
                   self.resultChannel?([path])
               }
           } catch {
               DispatchQueue.main.async {
                   self.resultChannel?(FlutterError(code: "SCAN_SAVE_ERROR", message: "Error", details: error.localizedDescription))
               }
           }
       }
   }

   func getDocumentsDirectory() -> URL {
       FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
   }

   private func saveSingleImage(image: UIImage) throws -> String {
       let tempDirPath = getDocumentsDirectory()
       let df = DateFormatter()
       df.dateFormat = "yyyyMMdd-HHmmss"
       let imagePath = tempDirPath.appendingPathComponent(df.string(from: Date()) + "-0.jpg")
       guard let data = image.jpegData(compressionQuality: 0.78) else {
           throw NSError(domain: "flutter_doc_scanner", code: 1001, userInfo: nil)
       }
       try data.write(to: imagePath, options: .atomic)
       return imagePath.path
   }

   public func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
       if currentMethod == "getScanDocuments" || currentMethod == "getScannedDocumentAsImages" {
           saveScannedImages(scan: scan)
       } else if currentMethod == "getScannedDocumentAsPdf" {
           saveScannedPdf(scan: scan)
       }
       controller.dismiss(animated: true)
   }
   
   // ... keep existing saveScannedImages and saveScannedPdf methods exactly as they are ...
   private func saveScannedImages(scan: VNDocumentCameraScan) {
       let tempDirPath = getDocumentsDirectory()
       let currentDateTime = Date()
       let df = DateFormatter()
       df.dateFormat = "yyyyMMdd-HHmmss"
       let formattedDate = df.string(from: currentDateTime)
       var filenames: [String] = []
       for i in 0 ..< scan.pageCount {
           let page = scan.imageOfPage(at: i)
           let url = tempDirPath.appendingPathComponent(formattedDate + "-\(i).png")
           try? page.pngData()?.write(to: url)
           filenames.append(url.path)
       }
       resultChannel?(filenames)
   }

   private func saveScannedPdf(scan: VNDocumentCameraScan) {
       let tempDirPath = getDocumentsDirectory()
       let currentDateTime = Date()
       let df = DateFormatter()
       df.dateFormat = "yyyyMMdd-HHmmss"
       let formattedDate = df.string(from: currentDateTime)
       let pdfFilePath = tempDirPath.appendingPathComponent("\(formattedDate).pdf")
       let pdfDocument = PDFDocument()
       for i in 0 ..< scan.pageCount {
           let pageImage = scan.imageOfPage(at: i)
           if let pdfPage = PDFPage(image: pageImage) {
               pdfDocument.insert(pdfPage, at: pdfDocument.pageCount)
           }
       }
       do {
           try pdfDocument.write(to: pdfFilePath)
           resultChannel?(pdfFilePath.path)
       } catch {
           resultChannel?(FlutterError(code: "PDF_CREATION_ERROR", message: "Failed", details: error.localizedDescription))
       }
   }

   public func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
       resultChannel?(nil)
       controller.dismiss(animated: true)
   }

   public func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
       resultChannel?(nil)
       controller.dismiss(animated: true)
   }
}