package com.dennomuso.koeon.core.auth

import android.content.Context
import java.security.SecureRandom

private const val DEVICE_NAME_KEY = "device_display_name_v1"
internal const val DEVICE_NAME_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

internal interface DeviceDisplayNameValues {
    fun read(key: String): String?
    fun write(key: String, value: String)
}

internal class PersistentDeviceDisplayNameStore(
    private val values: DeviceDisplayNameValues,
    private val prefix: String,
    private val randomIndex: (Int) -> Int = SecureRandom()::nextInt,
) {
    fun getOrCreate(): String {
        val existing = values.read(DEVICE_NAME_KEY)
        if (existing != null && isValidDeviceDisplayName(existing)) return existing
        val generated = buildString {
            append(prefix)
            append('-')
            repeat(6) { append(DEVICE_NAME_ALPHABET[randomIndex(DEVICE_NAME_ALPHABET.length)]) }
        }
        values.write(DEVICE_NAME_KEY, generated)
        return generated
    }
}

internal fun isValidDeviceDisplayName(value: String): Boolean =
    value.matches(Regex("^(IPH|IPD|AND|WIN|MAC|LNX|WEB)-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}$"))

class AndroidDeviceDisplayNameStore(context: Context) {
    private val store = PersistentDeviceDisplayNameStore(
        values = SharedPreferencesDeviceDisplayNameValues(
            context.getSharedPreferences("koeon_device_display", Context.MODE_PRIVATE),
        ),
        prefix = "AND",
    )

    fun getOrCreate(): String = store.getOrCreate()
}

private class SharedPreferencesDeviceDisplayNameValues(
    private val preferences: android.content.SharedPreferences,
) : DeviceDisplayNameValues {
    override fun read(key: String): String? = preferences.getString(key, null)
    override fun write(key: String, value: String) {
        preferences.edit().putString(key, value).apply()
    }
}
