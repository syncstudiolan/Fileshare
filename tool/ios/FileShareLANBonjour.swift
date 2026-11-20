import Foundation
import Flutter
import UIKit
import Darwin

/// DNS-SD transport discovery; actual files continue over LanEngine's TCP
/// listener. Unlike raw broadcast, standard Bonjour doesn't require the
/// restricted Apple multicast-broadcast entitlement.
@available(iOS 16.0, *)
final class FileShareLANBonjour: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private static var retained: FileShareLANBonjour?
    private let channel: FlutterMethodChannel
    private let browser = NetServiceBrowser()
    private var advertiser: NetService?
    private var found: [String: NetService] = [:]
    private var resolvedIds: [String: String] = [:]
    private var ownId = ""

    static func register(messenger: FlutterBinaryMessenger) {
        let bridge = FileShareLANBonjour(messenger: messenger)
        retained = bridge
        bridge.channel.setMethodCallHandler { [weak bridge] call, result in
            guard let bridge = bridge else { result(FlutterMethodNotImplemented); return }
            switch call.method {
            case "start":
                guard let args = call.arguments as? [String: Any],
                      let id = args["id"] as? String,
                      let port = args["port"] as? Int,
                      port > 0 && port <= 65535 else {
                    result(FlutterError(code: "BAD_DISCOVERY_SETTINGS",
                      message: "Missing LAN ID or TCP port", details: nil))
                    return
                }
                bridge.start(id: id, name: args["name"] as? String ?? "iPhone", port: port)
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

    private init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "file_share.lan_discovery",
                                       binaryMessenger: messenger)
        super.init()
        browser.delegate = self
    }

    private func start(id: String, name: String, port: Int) {
        stop()
        ownId = id
        let clean = String(name.prefix(28)).replacingOccurrences(of: ".", with: "-")
        let instance = clean + "-" + String(id.prefix(8))
        let service = NetService(domain: "local.", type: "_fileshare._tcp.",
                                 name: instance, port: Int32(port))
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "id": Data(id.utf8), "n": Data(name.utf8)
        ]))
        advertiser = service
        service.publish()
        browser.searchForServices(ofType: "_fileshare._tcp.", inDomain: "local.")
    }

    private func stop() {
        browser.stop()
        advertiser?.stop()
        advertiser = nil
        found.values.forEach { $0.stop() }
        found.removeAll()
        resolvedIds.removeAll()
    }

    private func refresh() {
        // Clear discovered peers before browsing again after Wi-Fi changes.
        // Otherwise stale entries can remain visible after network switches.
        for id in Set(resolvedIds.values) {
            channel.invokeMethod("lost", arguments: ["id": id])
        }
        browser.stop()
        found.removeAll()
        resolvedIds.removeAll()
        browser.searchForServices(ofType: "_fileshare._tcp.", inDomain: "local.")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService, moreComing: Bool) {
        let key = service.name
        found[key] = service
        service.delegate = self
        service.resolve(withTimeout: 8)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService, moreComing: Bool) {
        found.removeValue(forKey: service.name)
        if let id = resolvedIds.removeValue(forKey: service.name) {
            channel.invokeMethod("lost", arguments: ["id": id])
        }
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        guard let txt = service.txtRecordData() else { return }
        let fields = NetService.dictionary(fromTXTRecord: txt)
        guard let idData = fields["id"],
              let id = String(data: idData, encoding: .utf8),
              !id.isEmpty, id != ownId else { return }
        let name = fields["n"].flatMap { String(data: $0, encoding: .utf8) }
            ?? service.name
        let address = (service.addresses ?? []).compactMap(ipv4).first
        guard let ip = address, service.port > 0 else { return }
        resolvedIds[service.name] = id
        channel.invokeMethod("peer", arguments: [
            "id": id, "name": name, "address": ip, "port": service.port
        ])
    }

    private func ipv4(_ data: Data) -> String? {
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr_in>.size
            else { return nil }
            let ptr = base.assumingMemoryBound(to: sockaddr.self)
            guard Int32(ptr.pointee.sa_family) == AF_INET else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let code = getnameinfo(ptr, socklen_t(raw.count),
                                   &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST)
            guard code == 0 else { return nil }
            return host.withUnsafeBufferPointer {
                guard let p = $0.baseAddress else { return nil }
                return String(cString: p)
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        channel.invokeMethod("error", arguments: [
            "message": "Could not resolve nearby service: " + sender.name
        ])
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        channel.invokeMethod("error", arguments: [
            "message": "Could not advertise local device"
        ])
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        channel.invokeMethod("error", arguments: [
            "message": "Bonjour browse blocked. Enable File Share in Settings > Privacy & Security > Local Network."
        ])
    }
}
