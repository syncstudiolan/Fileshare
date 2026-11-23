import Cocoa
import FlutterMacOS

/// Selected Finder download location is a security-scoped bookmark, not an
/// assumed ~/Downloads path. The sandbox needs user-selected RW entitlement.
final class FileShareDownloadFolder: NSObject {
  static let shared = FileShareDownloadFolder()
  private let bookmarkKey = "file_share_macos_download_folder_bookmark_v1"
  private var pendingResult: FlutterResult?
  private var pendingExport: (URL, String)?

  static func register(messenger: FlutterBinaryMessenger) {
    let bridge = FileShareDownloadFolder.shared
    FlutterMethodChannel(name: "file_share.downloads", binaryMessenger: messenger)
      .setMethodCallHandler { call, reply in
        DispatchQueue.main.async { bridge.handle(call, reply: reply) }
      }
  }

  private func handle(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
    switch call.method {
    case "getDirectory":
      reply(savedFolder()?.path)
    case "chooseDirectory":
      guard pendingResult == nil else {
        reply(FlutterError(code: "BUSY", message: "A folder picker is already open.", details: nil))
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
        reply(FlutterError(code: "SOURCE_MISSING", message: "Received file missing.", details: nil))
        return
      }
      guard pendingResult == nil else {
        reply(FlutterError(code: "BUSY", message: "Another download is in progress.", details: nil))
        return
      }
      pendingResult = reply
      if let folder = savedFolder() {
        copyFile(source: URL(fileURLWithPath: path), name: name, into: folder)
      } else {
        pendingExport = (URL(fileURLWithPath: path), name)
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
                           options: [.withSecurityScope],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
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
    let panel = NSOpenPanel()
    panel.message = "Choose where File Share should save received files."
    panel.prompt = "Use This Folder"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.begin { [weak self] response in
      guard let self = self else { return }
      guard response == .OK, let folder = panel.url else {
        self.finish(nil)
        return
      }
      do {
        let hasScope = folder.startAccessingSecurityScopedResource()
        defer { if hasScope { folder.stopAccessingSecurityScopedResource() } }
        let bookmark = try folder.bookmarkData(options: [.withSecurityScope],
          includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: self.bookmarkKey)
        if let (source, name) = self.pendingExport {
          self.pendingExport = nil
          self.copyFile(source: source, name: name, into: folder)
        } else {
          self.finish(folder.path)
        }
      } catch {
        self.fail("Finder folder permission could not be saved: \(error.localizedDescription)")
      }
    }
  }

  private func copyFile(source: URL, name: String, into folder: URL) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let hasScope = folder.startAccessingSecurityScopedResource()
      defer { if hasScope { folder.stopAccessingSecurityScopedResource() } }
      do {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
          throw NSError(domain: "FileShare", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Received file no longer exists."])
        }
        let clean = URL(fileURLWithPath: name).lastPathComponent
        guard !clean.isEmpty && clean != "." && clean != ".." else {
          throw NSError(domain: "FileShare", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Invalid file name."])
        }
        let ext = (clean as NSString).pathExtension
        let stem = (clean as NSString).deletingPathExtension
        var destination = folder.appendingPathComponent(clean)
        var count = 1
        while fm.fileExists(atPath: destination.path) {
          count += 1
          let candidate = ext.isEmpty ? "\(stem) (\(count))" : "\(stem) (\(count)).\(ext)"
          destination = folder.appendingPathComponent(candidate)
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinateError: NSError?
        var copyError: Error?
        coordinator.coordinate(writingItemAt: destination, options: [],
                               error: &coordinateError) { coordinated in
          do { try fm.copyItem(at: source, to: coordinated) }
          catch { copyError = error }
        }
        if let error = coordinateError { throw error }
        if let error = copyError { throw error }
        let location = destination.path
        DispatchQueue.main.async { self?.finish(location) }
      } catch {
        let message = "Cannot save to chosen Finder folder: \(error.localizedDescription). Reselect in Settings."
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
