package io.uaena.cliplink.store

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** A device this one has agreed to sync with, plus the last address it was reachable at. */
data class TrustedDevice(
    val publicKey: String,
    val address: String? = null,
)

/**
 * The list of devices allowed to send this one clipboard data. Mirrors the
 * Windows daemon's TrustStore.cs and the HarmonyOS port's TrustStore.ets,
 * including the same known gap: not encrypted at rest. That is deliberate
 * parity rather than an oversight - the trust store holds public keys, and
 * "fixing" it on one platform only would make the three implementations
 * diverge for no security gain.
 */
class TrustStore(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("cliplink_trust_store", Context.MODE_PRIVATE)

    @Synchronized
    fun all(): List<TrustedDevice> {
        val json = prefs.getString(DEVICES_KEY, "[]") ?: "[]"
        return try {
            val array = JSONArray(json)
            (0 until array.length()).mapNotNull { i ->
                val obj = array.optJSONObject(i) ?: return@mapNotNull null
                val publicKey = obj.optString("publicKey", "")
                if (publicKey.isEmpty()) return@mapNotNull null
                val address = obj.optString("address", "").takeIf { it.isNotEmpty() }
                TrustedDevice(publicKey, address)
            }
        } catch (e: Exception) {
            // Corrupt value - regenerate rather than crash startup, the same
            // policy the Windows and HarmonyOS stores use.
            emptyList()
        }
    }

    @Synchronized
    private fun save(devices: List<TrustedDevice>) {
        val array = JSONArray()
        devices.forEach { device ->
            array.put(
                JSONObject().apply {
                    put("publicKey", device.publicKey)
                    device.address?.let { put("address", it) }
                },
            )
        }
        prefs.edit().putString(DEVICES_KEY, array.toString()).commit()
    }

    /**
     * Upsert. An existing entry keeps its cached address when [address] is
     * null, so back-filling an address later never erases one - that
     * back-fill is what makes off-LAN reconnect work for a peer that was
     * originally paired in the other direction.
     */
    @Synchronized
    fun trust(publicKey: String, address: String? = null) {
        val devices = all().toMutableList()
        val index = devices.indexOfFirst { it.publicKey == publicKey }
        if (index >= 0) {
            devices[index] = devices[index].copy(address = address ?: devices[index].address)
        } else {
            devices.add(TrustedDevice(publicKey, address))
        }
        save(devices)
    }

    @Synchronized
    fun untrust(publicKey: String) = save(all().filterNot { it.publicKey == publicKey })

    fun isTrusted(publicKey: String): Boolean = all().any { it.publicKey == publicKey }

    fun withAddress(): List<TrustedDevice> = all().filter { !it.address.isNullOrEmpty() }

    private companion object {
        const val DEVICES_KEY = "trusted_devices"
    }
}
