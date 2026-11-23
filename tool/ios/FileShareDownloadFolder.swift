import UIKit
import Flutter
import UniformTypeIdentifiers

/// iOS Files app destination: a document-provider folder cannot be created
/// via a guessed /var/mobile/.../Downloads path. The picker grants access;
/// a bookmark remembers the exact user-selected location on this device.
final class FileShareDownloadFolder: NSObject, UIDocumentPickerDelegate {
  static let shared = FileShareDownloadFolder()
  private let bookmarkKey = "file_share_ios_download_folder_bookmark_v1"
  private var pendingResult: FlutterResult?
  private var pendingExport: (URL, String)?

  static func register(messenger: FlutterBinaryMessenger) {
    let bridge = FileShareDownloadFolder.shared
    let channel = FlutterMethodChannel(
      name: "file_share.downloads", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, reply in
      DispatchQueue.main.async { bridge.handle(call, reply: reply) }
    }
  }

  private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
    switch call.method {
    case "getDirectory":
      reply(savedFolder()?.lastPathComponent)
    case "chooseDirectory":
      guard pendingResult == nil else {
        reply(FlutterError(code: "BUSY", message: "A Files picker is already open.", details: nil))
        return
      }
      pendingResult = reply
      pendingExport = nil
      showPicker()
    case "exportFile":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String,
            let name = args["name"] as? String,
            FileManager.default.fileExists(atPath: path) else {
        reply(FlutterError(code: "SOURCE_MISSING", message: "Received file is unavailable.", details: nil))
        return
      }
      guard pendingResult == nil else {
        reply(FlutterError(code: "BUSY", message: "Another Files download is in progress.", details: nil))
        return
      }
      let source = URL(fileURLWithPath: path)
      if let folder = savedFolder() {
        pendingResult = reply
        copyFile(source: source, name: name, into: folder)
      } else {
        // First download: ask once; cancelling must NOT mark a file downloaded.
        pendingResult = reply
        pendingExport = (source, name)
        showPicker()
      }
    default:
      reply(FlutterMethodNotImplemented)
    }
  }

  private func savedFolder() -> URL? {
    guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else {
      return nil
    }
    do {
      var stale = false
      let folder = try URL(resolvingBookmarkData: bookmark,
                           options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
      if stale {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        return nil
      }
      return folder
    } catch {
      UserDefaults.standard.removeObject(forKey: bookmarkKey)
      return nil
    }
  }

  private func showPicker() {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
    guard var presenter = window?.rootViewController else {
      fail("No foreground iPhone window is available for Files.")
      return
    }
    while let presented = presenter.presentedViewController {
      presenter = presented
    }
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: [UTType.folder], asCopy: false)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController,
                      didPickDocumentsAt urls: [URL]) {
    guard let folder = urls.first else {
      finish(nil)
      return
    }
    do {
      let hasScope = folder.startAccessingSecurityScopedResource()
      defer { if hasScope { folder.stopAccessingSecurityScopedResource() } }
      let bookmark = try folder.bookmarkData(options: [],
        includingResourceValuesForKeys: nil, relativeTo: nil)
      UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
      if let (source, name) = pendingExport {
        pendingExport = nil
        copyFile(source: source, name: name, into: folder)
      } else {
        finish(folder.lastPathComponent)
      }
    } catch {
      fail("Files cannot remember this folder: \(error.localizedDescription)")
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(nil)
  }

  private func copyFile(source: URL, name: String, into folder: URL) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let hasScope = folder.startAccessingSecurityScopedResource()
      defer { if hasScope { folder.stopAccessingSecurityScopedResource() } }
      do {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
          throw NSError(domain: "FileShare", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Source file has disappeared."])
        }
        let clean = URL(fileURLWithPath: name).lastPathComponent
        guard !clean.isEmpty && clean != "." && clean != ".." else {
          throw NSError(domain: "FileShare", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Invalid file name."])
        }
        let ext = (clean as NSString).pathExtension
        let stem = (clean as NSString).deletingPathExtension
        var destination = folder.appendingPathComponent(clean, isDirectory: false)
        var count = 1
        while fm.fileExists(atPath: destination.path) {
          count += 1
          let replacement = ext.isEmpty ? "\(stem) (\(count))" : "\(stem) (\(count)).\(ext)"
          destination = folder.appendingPathComponent(replacement, isDirectory: false)
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinateError: NSError?
        var copyError: Error?
        coordinator.coordinate(writingItemAt: destination, options: [],
                               error: &coordinateError) { actual in
          do { try fm.copyItem(at: source, to: actual) }
          catch { copyError = error }
        }
        if let error = coordinateError { throw error }
        if let error = copyError { throw error }
        let saved = destination.path
        DispatchQueue.main.async { self?.finish(saved) }
      } catch {
        let message = "Cannot write to selected Files folder: \(error.localizedDescription). Change it in Settings."
        DispatchQueue.main.async { self?.fail(message) }
      }
    }
  }

  private func fail(_ message: String) {
    let reply = pendingResult
    pendingResult = nil
    pendingExport = nil
    reply?(FlutterError(code: "DOWNLOAD_FOLDER", message: message, details: nil))
  }

  private func finish(_ path: String?) {
    let reply = pendingResult
    pendingResult = nil
    pendingExport = nil
    reply?(path)
  }
}
