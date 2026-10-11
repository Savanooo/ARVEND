import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/domain/user.dart';
import '../auth/auth_controller.dart';
import '../errors/api_exception.dart';

/// Çökme ve beklenmeyen hata raporlama -- Firebase'e doğrudan bağlı olmayan
/// yüz. Gerçek uygulamada main.dart `FirebaseCrashReporter` ile ezer;
/// testlerde ve Firebase'in olmadığı yerde (iOS) varsayılan
/// [NoopCrashReporter] çalışır, hiçbir şey göndermez.
///
/// Gönderilen: hatanın türü/mesajı, yığın izi, uygulama sürümü, cihaz
/// modeli/Android sürümü (Crashlytics'in kendisi ekler), iç kullanıcı ve
/// firma kimliği. GÖNDERİLMEYEN: ad, kullanıcı adı, e-posta, telefon,
/// formlara yazılanlar. Sunucunun hata metinleri (müşteri adı vb. içerebilir)
/// raporlanmadan önce çıkarılır (bkz. [redactForCrashReport]). Envanter:
/// RELEASE.md §10.
abstract class CrashReporter {
  /// [fatal]: yakalanmamış hata (uygulama genel yakalayıcılarından geldi).
  /// Ekranların yakalayıp kullanıcıya mesaj gösterdiği ama beklenmeyen
  /// hatalar fatal DEĞİLDİR.
  Future<void> recordError(Object error, StackTrace? stack, {String? reason, bool fatal = false});

  Future<void> recordFlutterError(FlutterErrorDetails details, {bool fatal = false});

  /// Oturumdaki kullanıcı -- YALNIZCA iç kimlikler. Çıkışta ikisi de null.
  Future<void> setUser({String? userId, String? organizationId});
}

class NoopCrashReporter implements CrashReporter {
  const NoopCrashReporter();

  @override
  Future<void> recordError(Object error, StackTrace? stack, {String? reason, bool fatal = false}) async {}

  @override
  Future<void> recordFlutterError(FlutterErrorDetails details, {bool fatal = false}) async {}

  @override
  Future<void> setUser({String? userId, String? organizationId}) async {}
}

final crashReporterProvider = Provider<CrashReporter>((ref) => const NoopCrashReporter());

/// Raporlanan hata yerine geçen, kişisel veri taşımayan özet.
@immutable
class RedactedError {
  const RedactedError(this.summary);
  final String summary;

  @override
  String toString() => summary;
}

/// Raporlanacak hatadan kişisel veri taşıyabilecek kısımları çıkarır:
/// - [ApiException]'ın mesajı sunucudan gelir ("'Ahmet Yılmaz' zaten kayıtlı"
///   gibi) -- yalnızca türü, durum kodu ve makine kodu kalır.
/// - [DioException]'ın adresindeki sorgu (arama metni vb.) atılır.
/// - [FileSystemException]'ın yolu (dosya adı: "Ahmet Yılmaz sözleşme.pdf")
///   atılır; işlem ve işletim sistemi hata kodu kalır.
/// - [PlatformException]'ın (seçici/eklenti) mesajı ve ayrıntısı dosya yolu
///   taşıyabilir -- yalnızca kodu kalır.
/// Diğer hatalar olduğu gibi döner.
Object redactForCrashReport(Object error) => switch (error) {
      ApiException e => RedactedError(
          'ApiException(${[e.kind.name, if (e.statusCode != null) '${e.statusCode}', if (e.code != null) e.code].join(', ')})',
        ),
      DioException e => RedactedError(
          'DioException(${e.type.name}, ${e.response?.statusCode ?? '-'}, '
          '${e.requestOptions.method} ${e.requestOptions.path.split('?').first})',
        ),
      FileSystemException e => RedactedError(
          '${e.runtimeType}(${[
            e.message,
            if (e.osError case final os?) 'errno ${os.errorCode} ${os.message}'.trim(),
          ].join(', ')})',
        ),
      PlatformException e => RedactedError('PlatformException(${e.code})'),
      _ => error,
    };

/// Uygulama genelindeki yakalanmamış hata yakalayıcılar (main.dart kurar):
/// Flutter çerçevesinin hataları (FlutterError.onError), çerçeve dışındaki
/// yakalanmamış hatalar (PlatformDispatcher.onError) ve main'in
/// runZonedGuarded bölgesi ([onUncaught]).
class CrashHandlers {
  CrashHandlers._();

  static CrashReporter _reporter = const NoopCrashReporter();

  static void install(CrashReporter reporter) {
    _reporter = reporter;
    FlutterError.onError = (details) {
      // Konsola (geliştirmede) her zamanki gibi yazılır.
      FlutterError.presentError(details);
      unawaited(_reporter.recordFlutterError(details, fatal: true));
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      onUncaught(error, stack);
      return true;
    };
  }

  static void onUncaught(Object error, StackTrace stack) {
    if (!kReleaseMode) debugPrint('Yakalanmamış hata: $error\n$stack');
    unawaited(_reporter.recordError(error, stack, fatal: true));
  }
}

/// Oturumdaki kullanıcıyı raporlara bağlar: girişte iç kullanıcı ve firma
/// kimliği, çıkışta boş. Ad/kullanıcı adı ASLA gönderilmez.
void bindCrashReporterToSession(ProviderContainer container, CrashReporter reporter) {
  var bound = false;
  String? lastUserId;
  container.listen<AsyncValue<User?>>(
    authControllerProvider,
    (_, next) {
      if (next.isLoading) return;
      final user = next.valueOrNull;
      if (bound && user?.id == lastUserId) return;
      bound = true;
      lastUserId = user?.id;
      unawaited(reporter.setUser(userId: user?.id, organizationId: user?.organizationId));
    },
    fireImmediately: true,
  );
}
