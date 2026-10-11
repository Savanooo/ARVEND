import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../firebase/firebase_setup.dart';
import 'crash_reporter.dart';

/// Firebase Crashlytics (proje `arvend-8bc93`, bildirimle aynı). Yalnızca
/// release yapısında toplar: debug/profile'da toplama kapalıdır (ayrıca
/// android/app/src/debug ve profile manifest'leri açılışta da kapatır).
///
/// Crashlytics gradle eklentisi YOK (google-services eklentisi gibi; AGP 9):
/// eklenti yalnızca R8 eşleme dosyalarını (Java/Kotlin yığın izlerini
/// çözmek için) yükler. Dart hataları onsuz da tam yığın iziyle gelir;
/// eklentinin yokluğunda Crashlytics'in "build ID" denetimini FlutterFire
/// eklentisi kendi kaynağıyla kapatıyor (com.crashlytics.RequireBuildId).
class FirebaseCrashReporter implements CrashReporter {
  FirebaseCrashReporter._(this._crashlytics);
  final FirebaseCrashlytics _crashlytics;

  /// Firebase başlatılamazsa (iOS henüz kurulmadı vb.) null -- uygulama
  /// raporsuz çalışır.
  static Future<CrashReporter?> create() async {
    if (!await initFirebase()) return null;
    try {
      final crashlytics = FirebaseCrashlytics.instance;
      await crashlytics.setCrashlyticsCollectionEnabled(kReleaseMode);
      // Play ile sideload/geliştirici yapısının hataları ayırt edilsin.
      await crashlytics.setCustomKey('dagitim', AppConfig.distribution);
      return FirebaseCrashReporter._(crashlytics);
    } catch (e) {
      debugPrint('Çökme raporlama başlatılamadı: $e');
      return null;
    }
  }

  @override
  Future<void> recordError(Object error, StackTrace? stack, {String? reason, bool fatal = false}) async {
    try {
      await _crashlytics.recordError(redactForCrashReport(error), stack, reason: reason, fatal: fatal);
    } catch (e) {
      // Rapor gönderilemese de uygulama sürer.
      debugPrint('Hata raporlanamadı: $e');
    }
  }

  /// FirebaseCrashlytics.recordFlutterError'ın aynısı; tek fark hata
  /// metninin önce [redactForCrashReport]'tan geçmesi (konsola yazmayı
  /// CrashHandlers zaten yaptı).
  @override
  Future<void> recordFlutterError(FlutterErrorDetails details, {bool fatal = false}) async {
    try {
      final exception = redactForCrashReport(details.exception);
      await _crashlytics.recordError(
        exception is RedactedError ? exception : details.exceptionAsString(),
        details.stack,
        reason: details.context?.toStringDeep(minLevel: DiagnosticLevel.info).trim(),
        information: details.informationCollector?.call() ?? const [],
        printDetails: false,
        fatal: fatal,
      );
    } catch (e) {
      debugPrint('Hata raporlanamadı: $e');
    }
  }

  @override
  Future<void> setUser({String? userId, String? organizationId}) async {
    try {
      await _crashlytics.setUserIdentifier(userId ?? '');
      await _crashlytics.setCustomKey('firma_id', organizationId ?? '');
    } catch (e) {
      debugPrint('Rapor kullanıcısı ayarlanamadı: $e');
    }
  }
}
