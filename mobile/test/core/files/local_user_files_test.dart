import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/files/local_documents.dart';

import '../../test_utils/fake_api_client.dart';

/// Çıkışta telefonda kullanıcıya ait dosya kalmaz (mobil-genel-i4): ortak
/// şantiye telefonunda sonraki kişi öncekinin maaş dökümünü, teklifini,
/// fotoğrafını bulmasın.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory base;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    base = await Directory.systemTemp.createTemp('arvend_user_files');
    for (final name in [...LocalUserFiles.directories, 'baska-uygulama-verisi']) {
      final dir = Directory('${base.path}/$name')..createSync();
      File('${dir.path}/dosya.pdf').writeAsBytesSync([1]);
    }
  });
  tearDown(() => base.delete(recursive: true));

  bool exists(String name) => Directory('${base.path}/$name').existsSync();

  test('belgeler, fotoğraf önbelleği ve paylaşım kopyaları silinir; başka şeye dokunulmaz', () async {
    await LocalUserFiles(baseDirectory: () async => base).clear();

    expect(exists(LocalDocuments.directoryName), isFalse);
    expect(exists(kProjectPhotoCacheDirectory), isFalse);
    expect(exists(kSharePlusDirectory), isFalse);
    expect(exists('baska-uygulama-verisi'), isTrue);
  });

  test('geçici dizin alınamazsa hata fırlatmaz', () async {
    await LocalUserFiles(baseDirectory: () async => throw const FileSystemException('yok')).clear();
  });

  Map<String, dynamic> me() => {
        'id': 'u1',
        'organization_id': 'org1',
        'username': 'ali',
        'full_name': 'Ali Usta',
        'role': 'kullanici',
        'is_active': true,
        'must_change_password': false,
        'onboarding_completed': true,
        'onboarding_step': 'completed',
        'permissions': <String>[],
      };

  Future<ProviderContainer> signedIn(FakeHttpClientAdapter adapter) async {
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(await buildFakeApiClient(adapter)),
      localUserFilesProvider.overrideWithValue(LocalUserFiles(baseDirectory: () async => base)),
    ]);
    addTearDown(container.dispose);
    await container.read(authControllerProvider.future);
    return container;
  }

  Future<void> settle() async {
    for (var i = 0; i < 20 && exists(LocalDocuments.directoryName); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('çıkış yapınca kullanıcının dosyaları silinir (sunucuya ulaşılamasa da)', () async {
    final c = await signedIn(FakeHttpClientAdapter(script: {
      '/auth/me': [(status: 200, body: me())],
      '/auth/logout': [(status: 503, body: {'error': 'x'})],
    }));

    await c.read(authControllerProvider.notifier).logout();
    await settle();

    expect(exists(LocalDocuments.directoryName), isFalse);
    expect(exists(kProjectPhotoCacheDirectory), isFalse);
  });

  test('oturum süresi dolunca da silinir', () async {
    final c = await signedIn(FakeHttpClientAdapter(script: {
      '/auth/me': [(status: 200, body: me())],
    }));

    c.read(authControllerProvider.notifier).sessionExpired();
    await settle();

    expect(exists(LocalDocuments.directoryName), isFalse);
  });
}
