package com.arvendyapi.arvend

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
    }

    // Telefona bildirim: Android 8+ kanalsız bildirim göstermez. Kanal
    // kimliği backend (fcm.Send channel_id) ve manifest'teki
    // default_notification_channel_id ile BİREBİR aynı. Yüksek önem: görev
    // ve plan ataması ekranın üstünde belirsin.
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL,
            "Bildirimler",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply { description = "Görev, plan, onay ve duyuru bildirimleri" }
        manager.createNotificationChannel(channel)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Uzaktan güncelleme (lib/core/update/apk_installer.dart): Android 8+
        // uygulama başına "bilinmeyen kaynaklardan yükleme" iznini sorar ve
        // izin yoksa kullanıcıyı doğrudan bu uygulamanın ayar sayfasına
        // götürür. Kurulum ekranının kendisi open_filex ile açılır.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canRequestPackageInstalls" -> result.success(canRequestPackageInstalls())
                    "openInstallPermissionSettings" -> result.success(openInstallPermissionSettings())
                    else -> result.notImplemented()
                }
            }
    }

    private fun canRequestPackageInstalls(): Boolean =
        // Android 8 öncesinde uygulama başına izin yok; karar kurulum
        // ekranına (genel "Bilinmeyen kaynaklar" ayarına) kalır.
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()

    private fun openInstallPermissionSettings(): Boolean {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
        } else {
            Intent(Settings.ACTION_SECURITY_SETTINGS)
        }
        return try {
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    private companion object {
        // lib/core/update/apk_installer.dart'taki kanal adıyla BİREBİR aynı.
        const val UPDATE_CHANNEL = "com.arvendyapi.arvend/app_update"
        const val NOTIFICATION_CHANNEL = "arvend_bildirimler"
    }
}
