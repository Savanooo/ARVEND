import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

const kApkMimeType = 'application/vnd.android.package-archive';

enum ApkInstallResult {
  /// Android'in kurulum ekranı açıldı (kurulumun kendisi artık sistemde).
  opened,

  /// "Bilinmeyen uygulamaları yükle" izni bu uygulamaya verilmemiş --
  /// kullanıcı Ayarlar'dan açmalı.
  permissionRequired,

  /// Kurulum ekranı açılamadı.
  failed,
}

/// Kurulum ekranını açma soyutlaması -- testlerde sahtesi verilir.
abstract interface class ApkInstaller {
  Future<ApkInstallResult> install(String apkPath);

  /// Bu uygulamanın bilinmeyen uygulama yükleme izni sayfasını açar
  /// (üzerindeki anahtar: "Bu kaynaktan izin ver").
  Future<void> openInstallPermissionSettings();
}

/// Gerçek Android uygulaması: izin kontrolü + ayar sayfası küçük bir
/// platform kanalıyla (MainActivity.kt), kurulum ekranı mevcut `open_filex`
/// ile açılır (kendi FileProvider'ı uygulamanın cache dizinini kapsar).
class PlatformApkInstaller implements ApkInstaller {
  const PlatformApkInstaller();

  // MainActivity.kt'deki kanal adıyla BİREBİR aynı olmalı.
  static const _channel = MethodChannel('com.arvendyapi.arvend/app_update');

  /// Android 8+ uygulama başına "bilinmeyen kaynak" izni. Kanal yoksa ya da
  /// hata verirse true sayılır -- karar Android'in kendi kurulum ekranına
  /// bırakılır (o da gerekirse kendi uyarısını gösterir).
  Future<bool> _canRequestPackageInstalls() async {
    try {
      return await _channel.invokeMethod<bool>('canRequestPackageInstalls') ?? true;
    } on PlatformException catch (e) {
      debugPrint('Güncelleme: kurulum izni okunamadı: ${e.message}');
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  @override
  Future<ApkInstallResult> install(String apkPath) async {
    if (!await _canRequestPackageInstalls()) return ApkInstallResult.permissionRequired;
    try {
      final result = await OpenFilex.open(apkPath, type: kApkMimeType);
      return switch (result.type) {
        ResultType.done => ApkInstallResult.opened,
        ResultType.permissionDenied => ApkInstallResult.permissionRequired,
        _ => ApkInstallResult.failed,
      };
    } catch (e) {
      debugPrint('Güncelleme: kurulum ekranı açılamadı: $e');
      return ApkInstallResult.failed;
    }
  }

  @override
  Future<void> openInstallPermissionSettings() async {
    try {
      await _channel.invokeMethod<bool>('openInstallPermissionSettings');
    } on PlatformException catch (e) {
      debugPrint('Güncelleme: ayar sayfası açılamadı: ${e.message}');
    } on MissingPluginException {
      // Kanal yok (ör. eski bir derleme) -- kullanıcı metindeki yolu izler.
    }
  }
}
