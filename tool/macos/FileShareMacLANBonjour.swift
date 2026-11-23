import Cocoa
import FlutterMacOS
import Foundation
import Darwin

/// macOS DNS-SD peer discovery. The existing LanEngine TCP listener still
/// receives files; only discovery/advertisement is native. The service type,
/// TXT keys and IPv4 peer events match Android NsdManager and iOS NetService.
final class FileShareMacLANBonjour: NSObject,
    NetServiceBrowserDelegate, NetServiceDelegate {
  static let shared = FileShareMacLANBonjour()

  private var channel: FlutterMethodChannel?
  private let browser = NetServiceBrowser()
  private var publisher: NetService?
  private var found: [String: NetService] = [:]
  private var resolvedIds: [String: String] = [:]
  private var ownId = ""
  private var ownName = ""
  private var ownPort = 0
  private var isRunning = false

  static func register(messenger: FlutterBinaryMessenger) {
    let bridge = FileShareMacLANBonjour.shared
    let channel = FlutterMethodChannel(
      name: "file_share.lan_discovery", binaryMessenger: messenger)
    bridge.channel = channel
    channel.setMethodCallHandler { [weak bridge] call, result in
      guard let bridge = bridge else {
        result(FlutterMethodNotImplemented)
        return
      }
      DispatchQueue.main.async {
        switch call.method {
        case "start":
          guard let args = call.arguments as? [String: Any],
                let id = args["id"] as? String,
                let port = args["port"] as? Int,
                !id.isEmpty, id.count <= 100, (1...65535).contains(port)
          else {
            result(FlutterError(code: "BAD_LAN_SETTINGS",
              message: "Missing device ID or TCP receiver port.", details: nil))
            return
          }
          bridge.start(id: id,
            name: args["name"] as? String ?? Host.current().localizedName ?? "Mac",
            port: port)
          result(nil)
        case "refresh":
          bridge.refresh()
          result(nil)
        case "stop":
          bridge.stop()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  private override init() {
    super.init()
    browser.delegate = self
  }

  private func start(id: String, name: String, port: Int) {
    if isRunning && ownId == id && ownPort == port { return }
    stop()
    ownId = id
    ownName = name
    ownPort = port
    let cleanName = name.prefix(25).replacingOccurrences(of: ".", with: "-")
    let instance = cleanName + "-" + String(id.prefix(8))
    let service = NetService(domain: "local.", type: "_fileshare._tcp.",
                             name: instance, port: Int32(port))
    service.delegate = self
    service.setTXTRecord(NetService.data(fromTXTRecord: [
      "id": Data(id.utf8),
      "n": Data(name.utf8)
    ]))
    publisher = service
    isRunning = true
    service.publish()
    browser.searchForServices(ofType: "_fileshare._tcp.", inDomain: "local.")
  }

  private func stop() {
    isRunning = false
    browser.stop()
    publisher?.stop()
    publisher = nil
    for service in found.values { service.stop() }
    found.removeAll()
    resolvedIds.removeAll()
  }

  private func refresh() {
    guard isRunning else { return }
    // Restart browsing after a manual refresh or network change. Keep the
    // advertisement published, and do not produce an unbounded UDP poll.
    for id in Set(resolvedIds.values) {
      channel?.invokeMethod("lost", arguments: ["id": id])
    }
    browser.stop()
    for service in found.values { service.stop() }
    found.removeAll()
    resolvedIds.removeAll()
    browser.searchForServices(ofType: "_fileshare._tcp.", inDomain: "local.")
  }

  func netServiceBrowser(_ browser: NetServiceBrowser,
                         didFind service: NetService,
                         moreComing: Bool) {
    guard isRunning else { return }
    found[service.name] = service
    service.delegate = self
    service.resolve(withTimeout: 10)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser,
                         didRemove service: NetService,
                         moreComing: Bool) {
    found.removeValue(forKey: service.name)
    if let id = resolvedIds.removeValue(forKey: service.name) {
      channel?.invokeMethod("lost", arguments: ["id": id])
    }
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard isRunning else { return }
    let fields = sender.txtRecordData()
      .map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
    guard let bytes = fields["id"],
          let id = String(data: bytes, encoding: .utf8),
          !id.isEmpty, id.count <= 100, id != ownId,
          sender.port > 0, sender.port <= 65535 else { return }

    // Prefer usable LAN IPv4 addresses; 127.x is never a remote host and
    // 169.254.x link-local addresses should only be fallback candidates.
    let candidates = (sender.addresses ?? []).compactMap(ipv4Address)
    guard let ip = candidates.first(where: {
        !$0.hasPrefix("127.") && !$0.hasPrefix("169.254.")
      }) ?? candidates.first(where: { !$0.hasPrefix("127.") })
    else { return }
    let name = fields["n"].flatMap { String(data: $0, encoding: .utf8) }
      ?? sender.name
    resolvedIds[sender.name] = id
    channel?.invokeMethod("peer", arguments: [
      "id": id, "name": name, "address": ip, "port": sender.port
    ])
  }

  private func ipv4Address(_ data: Data) -> String? {
    data.withUnsafeBytes { raw -> String? in
      guard let base = raw.baseAddress,
            raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
      let address = base.assumingMemoryBound(to: sockaddr.self)
      guard Int32(address.pointee.sa_family) == AF_INET else { return nil }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let status = getnameinfo(address, socklen_t(raw.count),
                               &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST)
      guard status == 0 else { return nil }
      return host.withUnsafeBufferPointer { buffer in
        guard let ptr = buffer.baseAddress else { return nil }
        return String(cString: ptr)
      }
    }
  }

  func netService(_ sender: NetService,
                  didNotResolve errorDict: [String: NSNumber]) {
    report("Could not resolve nearby peer: \(sender.name)")
  }

  func netService(_ sender: NetService,
                  didNotPublish errorDict: [String: NSNumber]) {
    report("Mac LAN advertisement blocked. Check macOS Local Network permission and firewall.")
  }

  func netServiceBrowser(_ browser: NetServiceBrowser,
                         didNotSearch errorDict: [String: NSNumber]) {
    report("Bonjour browsing failed. Allow File Share in macOS Settings > Privacy & Security > Local Network.")
  }

  private func report(_ message: String) {
    channel?.invokeMethod("error", arguments: ["message": message])
  }
}
