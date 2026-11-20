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

        discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                error("Bonjour discovery failed ($errorCode)")
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                if (!info.serviceType.startsWith("_fileshare._tcp")) return
                nsd.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
                    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                        val peerId = serviceInfo.attributes["id"]?.toString(Charsets.UTF_8)
                            ?: return
                        if (peerId.isEmpty() || peerId == ownId) return
                        val address = serviceInfo.host
                        if (address !is Inet4Address) return
                        val peerName = serviceInfo.attributes["n"]?.toString(Charsets.UTF_8)
                            ?: serviceInfo.serviceName
                        seen[serviceInfo.serviceName] = peerId
                        emit("peer", mapOf(
                            "id" to peerId, "name" to peerName,
                            "address" to address.hostAddress, "port" to serviceInfo.port
                        ))
                    }
                })
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                val id = seen.remove(info.serviceName) ?: return
                emit("lost", mapOf("id" to id))
            }
        }
        try {
            nsd.discoverServices("_fileshare._tcp.", NsdManager.PROTOCOL_DNS_SD, discovery!!)
        } catch (e: Exception) {
            error("Bonjour browse: " + (e.message ?: "failed"))
            discovery = null
        }
    }

    private fun stop() {
        discovery?.let { try { nsd.stopServiceDiscovery(it) } catch (_: Exception) {} }
        discovery = null
        registration?.let { try { nsd.unregisterService(it) } catch (_: Exception) {} }
        registration = null
        seen.clear()
        multicastLock?.let { try { if (it.isHeld) it.release() } catch (_: Exception) {} }
        multicastLock = null
    }
}
