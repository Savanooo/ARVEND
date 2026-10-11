
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/crash/crash_reporter.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/domain/user.dart';

/// Çökme raporlama (mobil-genel-g2): genel yakalayıcılar raporlar, raporlara
/// kişisel veri gitmez (yalnızca iç kullanıcı/firma kimliği; sunucunun hata
/// metni çıkarılır).

class _Recorded {
  _Recorded(this.error, this.fatal, {this.reason});
  final Object error;
  final bool fatal;
  final String? reason;
}

class _FakeReporter implements CrashReporter {
  final errors = <_Recorded>[];
  final flutterErrors = <FlutterErrorDetails>[];
  final users = <({String? userId, String? organizationId})>[];

  @override
  Future<void> recordError(Object error, StackTrace? stack, {String? reason, bool fatal = false}) async =>
      errors.add(_Recorded(error, fatal, reason: reason));

  @override
  Future<void> recordFlutterError(FlutterErrorDetails details, {bool fatal = false}) async =>
      flutterErrors.add(details);

  @override
  Future<void> setUser({String? userId, String? organizationId}) async =>
      users.add((userId: userId, organizationId: organizationId));
}

class _Auth extends AuthController {
  _Auth(this._user);
  final User? _user;
  @override
  Future<User?> build() async => _user;

  void signIn(User user) => state = AsyncData(user);
  void signOut() => state = const AsyncData(null);
}

User _user(String id) => User.fromJson({
      'id': id,
      'organization_id': 'org-$id',
      'username': 'ali.usta',
      'full_name': 'Ali Usta',
      'role': 'kullanici',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'permissions': <String>[],
    });

void main() {
  group('redactForCrashReport', () {
    test('sunucunun hata metni (müşteri adı vb.) rapora girmez', () {
      final redacted = redactForCrashReport(const ApiException(
        statusCode: 409,
        message: "'Ahmet Yılmaz' adlı müşteri zaten kayıtlı",
        kind: ApiErrorKind.conflict,
        code: 'duplicate_customer',
      ));
      expect(redacted, isA<RedactedError>());
      expect(redacted.toString(), 'ApiException(conflict, 409, duplicate_customer)');
      expect(redacted.toString(), isNot(contains('Ahmet')));
    });

    test('adresteki arama metni rapora girmez', () {
      final redacted = redactForCrashReport(DioException(
        requestOptions: RequestOptions(path: '/customers?q=Ahmet', method: 'GET'),
        type: DioExceptionType.connectionError,
      ));
      expect(redacted.toString(), 'DioException(connectionError, -, GET /customers)');
    });

    test('dosya yolu (müşteri adı taşıyabilen dosya adı) rapora girmez', () {
      const path = '/data/user/0/com.arvendyapi.arvend/cache/file_picker/1/Ahmet Yılmaz sözleşme.pdf';
      final noSpace = redactForCrashReport(
        const FileSystemException('Cannot write file', path, OSError('No space left on device', 28)),
      );
      expect(noSpace.toString(), 'FileSystemException(Cannot write file, errno 28 No space left on device)');

      final missing = redactForCrashReport(const PathNotFoundException(path, OSError('No such file', 2)));
      expect(missing.toString(), startsWith('PathNotFoundException('));
      expect(missing.toString(), isNot(contains('Ahmet')));

      final picker = redactForCrashReport(
        PlatformException(code: 'unknown_path', message: 'Failed to read $path', details: path),
      );
      expect(picker.toString(), 'PlatformException(unknown_path)');
    });

    test('diğer hatalar olduğu gibi kalır', () {
      final e = StateError('beklenmeyen durum');
      expect(redactForCrashReport(e), same(e));
    });
  });

  test('genel yakalayıcılar: Flutter hatası, çerçeve dışı hata ve korunan bölge raporlanır', () {
    final reporter = _FakeReporter();
    final previousFlutter = FlutterError.onError;
    final previousPlatform = PlatformDispatcher.instance.onError;
    try {
      CrashHandlers.install(reporter);

      final details = FlutterErrorDetails(exception: Exception('çizim hatası'), library: 'test');
      final presented = <FlutterErrorDetails>[];
      final previousPresent = FlutterError.presentError;
      FlutterError.presentError = presented.add;
      try {
        FlutterError.onError!(details);
      } finally {
        FlutterError.presentError = previousPresent;
      }
      expect(reporter.flutterErrors, [details]);
      expect(presented, [details], reason: 'konsola yazma davranışı korunur');

      final handled = PlatformDispatcher.instance.onError!(StateError('eklenti'), StackTrace.current);
      expect(handled, isTrue);

      CrashHandlers.onUncaught(ArgumentError('bölge'), StackTrace.current);

      expect(reporter.errors.map((r) => r.error.runtimeType), [StateError, ArgumentError]);
      expect(reporter.errors.every((r) => r.fatal), isTrue);
    } finally {
      FlutterError.onError = previousFlutter;
      PlatformDispatcher.instance.onError = previousPlatform;
    }
  });

  test('raporlara yalnızca iç kullanıcı ve firma kimliği bağlanır; çıkışta temizlenir', () async {
    final reporter = _FakeReporter();
    final auth = _Auth(_user('u1'));
    final container = ProviderContainer(overrides: [authControllerProvider.overrideWith(() => auth)]);
    addTearDown(container.dispose);

    bindCrashReporterToSession(container, reporter);
    await container.read(authControllerProvider.future);

    expect(reporter.users, [(userId: 'u1', organizationId: 'org-u1')]);

    auth.signOut();
    auth.signIn(_user('u2'));
    auth.signIn(_user('u2'));
    expect(reporter.users, [
      (userId: 'u1', organizationId: 'org-u1'),
      (userId: null, organizationId: null),
      (userId: 'u2', organizationId: 'org-u2'),
    ]);
  });
}
