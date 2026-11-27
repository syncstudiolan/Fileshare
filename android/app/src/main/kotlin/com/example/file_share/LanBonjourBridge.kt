package com.example.file_share

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

/**
 * DNS-SD peer discovery shared with iOS's NetService.
 * The existing Dart LanEngine still owns file transfers and TCP listener.
 * Run on the cached background FlutterEngine so foreground Activity changes
 * don't leave competing service registrations behind.
 */
class LanBonjourBridge(context: Context, messenger: BinaryMessenger) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val handler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "file_share.lan_discovery")
    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private val seen = mutableMapOf<String, String>()
    private var ownId: String = ""
    private var ownName: String = "Android"
    private var ownPort: Int = 49311
    private var generation = 0
    private var resolving = false
    private val pending = linkedMapOf<String, NsdServiceInfo>()
    private val present = mutableSetOf<String>()

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> try {
                    val id = call.argument<String>("id") ?: throw IllegalArgumentException("Missing device ID")
                    val port = call.argument<Int>("port") ?: throw IllegalArgumentException("Missing LAN port")
                    require(port in 1..65535 && id.isNotEmpty()) { "Invalid LAN settings" }
                    start(id, call.argument<String>("name") ?: "Android", port)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("BONJOUR_START_FAILED", e.message, null)
                }
                "refresh" -> {
                    // NsdManager continuously watches the subnet; no
                    // duplicate registrations or simultaneous discovery.
                    result.success(null)
                }
                "stop" -> {
                    stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun emit(method: String, data: Map<String, Any>) {
        handler.post { channel.invokeMethod(method, data) }
    }

    private fun error(message: String) = emit("error", mapOf("message" to message))

    private fun start(id: String, name: String, port: Int) {
        if (discovery != null && ownId == id && ownPort == port) return
        stop()
        ownId = id
        ownName = name
        ownPort = port
        try {
            multicastLock = wifi.createMulticastLock("fileshare-bonjour").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            error("Wi-Fi multicast receive permission: " + (e.message ?: "unavailable"))
        }
        val service = NsdServiceInfo().apply {
            serviceType = "_fileshare._tcp."
            serviceName = name.take(25).replace(".", "-") + "-" + id.take(8)
            setPort(port)
            setAttribute("id", id)
            setAttribute("n", name)
            setAttribute("v", "2")
        }
        registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {}
            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                error("Bonjour advertisement failed ($errorCode)")
            }
            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}
            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
        }
        try {
            nsd.registerService(service, NsdManager.PROTOCOL_DNS_SD, registration!!)
        } catch (e: Exception) {
            error("Bonjour advertise: " + (e.message ?: "failed"))
            registration = null
        }

        val session = generation
        discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                error("Bonjour discovery failed ($errorCode)")
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                handler.post {
                    if (session != generation || !info.serviceType.startsWith("_fileshare._tcp")) return@post
                    present.add(info.serviceName)
                    pending[info.serviceName] = info
                    resolveNext()
                }
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                handler.post {
                    if (session != generation) return@post
                    present.remove(info.serviceName)
                    pending.remove(info.serviceName)
                    val id = seen.remove(info.serviceName) ?: return@post
                    emit("lost", mapOf("id" to id))
                }
            }
        }
        try {
            nsd.discoverServices("_fileshare._tcp.", NsdManager.PROTOCOL_DNS_SD, discovery!!)
        } catch (e: Exception) {
            error("Bonjour browse: " + (e.message ?: "failed"))
            discovery = null
        }
    }

    // Older Android NSD permits only one outstanding resolve. Serialize
    // callbacks instead of silently dropping two of three simultaneous peers.
    private fun resolveNext() {
        if (resolving || pending.isEmpty()) return
        val entry = pending.entries.first()
        val key = entry.key
        val info = entry.value
        pending.remove(key)
        if (key !in present) { resolveNext(); return }
        resolving = true
        val session = generation
        fun finished(resolved: NsdServiceInfo?) {
            handler.post {
                if (session != generation) return@post
                resolving = false
                if (key in present && resolved != null) {
                    val peerId = resolved.attributes["id"]?.toString(Charsets.UTF_8)
                    val address = resolved.host
                    if (!peerId.isNullOrEmpty() && peerId != ownId &&
                        address is Inet4Address && !address.isLoopbackAddress &&
                        resolved.port in 1..65535) {
                        val peerName = resolved.attributes["n"]?.toString(Charsets.UTF_8)
                            ?: resolved.serviceName
                        seen[key] = peerId
                        emit("peer", mapOf(
                            "id" to peerId, "name" to peerName,
                            "address" to (address.hostAddress ?: ""),
                            "port" to resolved.port,
                            "v" to (resolved.attributes["v"]?.toString(Charsets.UTF_8) ?: "1")
                        ))
                    }
                } else if (key in present) {
                    // Back off; the other services still resolve immediately.
                    handler.postDelayed({
                        if (session == generation && key in present && key !in seen) {
                            pending[key] = info
                            resolveNext()
                        }
                    }, 3000)
                }
                resolveNext()
            }
        }
        try {
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = finished(null)
                override fun onServiceResolved(serviceInfo: NsdServiceInfo) = finished(serviceInfo)
            })
        } catch (_: Exception) { finished(null) }
    }

    private fun stop() {
        generation++
        resolving = false
        pending.clear()
        present.clear()
        discovery?.let { try { nsd.stopServiceDiscovery(it) } catch (_: Exception) {} }
        discovery = null
        registration?.let { try { nsd.unregisterService(it) } catch (_: Exception) {} }
        registration = null
        seen.clear()
        multicastLock?.let { try { if (it.isHeld) it.release() } catch (_: Exception) {} }
        multicastLock = null
    }
}
