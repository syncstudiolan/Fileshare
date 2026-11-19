import UIKit
import Flutter
import PDFKit
import VisionKit
import UniformTypeIdentifiers

/// iPhone-native PDF operations using Apple's system frameworks. This keeps
/// the IPA smaller than bundling the Android-only PDF engine and SDK.
@available(iOS 16.0, *)
final class FileShareIOSPDF {
    static func register(on controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: "file_share.ios_pdf", binaryMessenger: controller.binaryMessenger)
        channel.setMethodCallHandler { [weak controller] call, reply in
            guard let controller = controller else {
                reply(FlutterError(code: "UNAVAILABLE",
                    message: "iOS PDF view is not available", details: nil))
                return
            }
            guard call.method == "open" else {
                reply(FlutterMethodNotImplemented)
                return
            }
            let args = call.arguments as? [String: Any] ?? [:]
            let path = args["path"] as? String
            let document: PDFDocument
            if let path = path, !path.isEmpty {
                guard let opened = PDFDocument(url: URL(fileURLWithPath: path)) else {
                    reply(FlutterError(code: "INVALID_PDF",
                        message: "Cannot read this PDF", details: nil))
                    return
                }
                document = opened
            } else {
                document = PDFDocument()
            }
            let editor = FileSharePDFKitController(pdf: document)
            let nav = UINavigationController(rootViewController: editor)
            nav.modalPresentationStyle = .fullScreen
            controller.present(nav, animated: true)
            reply(nil)
        }
    }
}

@available(iOS 16.0, *)
final class FileSharePDFKitController: UIViewController,
    UIDocumentPickerDelegate, VNDocumentCameraViewControllerDelegate {

    private let document: PDFDocument
    private let pdfView = PDFView()
    private var temporaryFiles: [URL] = []

    init(pdf: PDFDocument) {
        self.document = pdf
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "File Share PDF"
        view.backgroundColor = .systemBackground
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = document
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .action,
                target: self, action: #selector(share)),
            UIBarButtonItem(title: "Edit", style: .plain,
                target: self, action: #selector(showEditMenu))
        ]
        let camera = UIBarButtonItem(barButtonSystemItem: .camera,
            target: self, action: #selector(scan))
        let merge = UIBarButtonItem(title: "Merge", style: .plain,
            target: self, action: #selector(merge))
        let pages = UIBarButtonItem(title: "Pages", style: .plain,
            target: self, action: #selector(pageActions))
        toolbarItems = [camera, UIBarButtonItem(barButtonSystemItem: .flexibleSpace,
            target: nil, action: nil),
            pages, UIBarButtonItem(barButtonSystemItem: .flexibleSpace,
            target: nil, action: nil), merge]
        navigationController?.isToolbarHidden = false
    }

    private func selectedIndex() -> Int {
        guard let page = pdfView.currentPage else { return 0 }
        return document.index(for: page)
    }

    private func error(_ text: String) {
        let alert = UIAlertController(title: "File Share PDF",
            message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    private func saveCopy() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileShare-\(UUID().uuidString).pdf")
        guard document.pageCount > 0 && document.write(to: url) else {
            error("No PDF pages are available to export.")
            return nil
        }
        temporaryFiles.append(url)
        return url
    }

    @objc private func share() {
        guard let url = saveCopy() else { return }
        let sheet = UIActivityViewController(
            activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem =
            navigationItem.rightBarButtonItems?.first
        present(sheet, animated: true)
    }

    @objc private func showEditMenu() {
        let alert = UIAlertController(title: "Edit PDF",
            message: "Changes remain in this editor until you share or save a copy.",
            preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Rotate page",
            style: .default) { [weak self] _ in self?.rotate() })
        alert.addAction(UIAlertAction(title: "Add text annotation",
            style: .default) { [weak self] _ in self?.annotate() })
        alert.addAction(UIAlertAction(title: "Duplicate page",
            style: .default) { [weak self] _ in self?.duplicate() })
        alert.addAction(UIAlertAction(title: "Delete page",
            style: .destructive) { [weak self] _ in self?.deletePage() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect =
            CGRect(x: view.bounds.midX, y: 0, width: 1, height: 1)
        present(alert, animated: true)
    }

    private func rotate() {
        guard let page = document.page(at: selectedIndex()) else { return }
        page.rotation = (page.rotation + 90) % 360
        pdfView.layoutDocumentView()
    }

    private func duplicate() {
        let index = selectedIndex()
        guard let page = document.page(at: index),
              let copy = page.copy() as? PDFPage else { return }
        document.insert(copy, at: min(index + 1, document.pageCount))
        pdfView.go(to: copy)
    }

    private func deletePage() {
        guard document.pageCount > 0 else { return }
        let index = selectedIndex()
        let confirm = UIAlertController(title: "Delete this page?",
            message: "Remove page \(index + 1) from this editing session?",
            preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        confirm.addAction(UIAlertAction(title: "Delete",
            style: .destructive) { [weak self] _ in
                guard let self = self else { return }
                self.document.removePage(at: index)
                if let next = self.document.page(at:
                    min(index, self.document.pageCount - 1)) {
                    self.pdfView.go(to: next)
                }
            })
        present(confirm, animated: true)
    }

    private func annotate() {
        guard let page = document.page(at: selectedIndex()) else {
            error("Add a scanned or imported page first.")
            return
        }
        let alert = UIAlertController(title: "Add PDF Text",
            message: "Type a text annotation", preferredStyle: .alert)
        alert.addTextField { field in field.placeholder = "Annotation" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add",
            style: .default) { [weak self] _ in
                guard let message = alert.textFields?.first?.text,
                    !message.isEmpty else { return }
                let bounds = page.bounds(for: .mediaBox)
                let note = PDFAnnotation(
                    bounds: CGRect(x: 20, y: bounds.midY,
                        width: max(80, bounds.width - 40), height: 65),
                    forType: .freeText, withProperties: nil)
                note.contents = message
                note.font = UIFont.systemFont(ofSize: 18)
                note.fontColor = .black
                note.color = UIColor.white.withAlphaComponent(0.7)
                page.addAnnotation(note)
                self?.pdfView.layoutDocumentView()
            })
        present(alert, animated: true)
    }

    @objc private func pageActions() {
        guard document.pageCount > 0 else { return }
        let current = selectedIndex()
        let alert = UIAlertController(title: "Reorder pages",
            message: "Current page \(current + 1) of \(document.pageCount)",
            preferredStyle: .actionSheet)
        if current > 0 {
            alert.addAction(UIAlertAction(title: "Move page earlier",
                style: .default) { [weak self] _ in
                    self?.movePage(from: current, to: current - 1)
                })
        }
        if current < document.pageCount - 1 {
            alert.addAction(UIAlertAction(title: "Move page later",
                style: .default) { [weak self] _ in
                    self?.movePage(from: current, to: current + 1)
                })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect =
            CGRect(x: view.bounds.midX, y: view.bounds.maxY,
                width: 1, height: 1)
        present(alert, animated: true)
    }

    private func movePage(from start: Int, to destination: Int) {
        guard let page = document.page(at: start) else { return }
        document.removePage(at: start)
        document.insert(page, at: destination)
        pdfView.go(to: page)
    }

    @objc private func merge() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType.pdf], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]) {
        for url in urls {
            let secure = url.startAccessingSecurityScopedResource()
            defer { if secure { url.stopAccessingSecurityScopedResource() } }
            guard let extra = PDFDocument(url: url) else { continue }
            for index in 0..<extra.pageCount {
                guard let original = extra.page(at: index),
                    let page = original.copy() as? PDFPage else { continue }
                document.insert(page, at: document.pageCount)
            }
        }
        pdfView.document = document
    }

    @objc private func scan() {
        guard VNDocumentCameraViewController.isSupported else {
            error("This device does not support document scanning.")
            return
        }
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = self
        present(scanner, animated: true)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController,
        didFinishWith scan: VNDocumentCameraScan) {
        for index in 0..<scan.pageCount {
            if let page = PDFPage(image: scan.imageOfPage(at: index)) {
                document.insert(page, at: document.pageCount)
            }
        }
        controller.dismiss(animated: true) { [weak self] in
            guard let self = self else { return }
            self.pdfView.document = self.document
        }
    }

    func documentCameraViewControllerDidCancel(
        _ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController,
        didFailWithError error: Error) {
        controller.dismiss(animated: true) { [weak self] in
            self?.error("Scanner failed: \(error.localizedDescription)")
        }
    }
}
