import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/update/app_release.dart';
import 'package:arvend/core/update/update_controller.dart';

import '../../test_utils/fake_api_client.dart';
import 'update_fakes.dart';

void main() {
  late DateTime now;
  late FakeHttpClientAdapter adapter;
  late FakeInstallService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 9, 28, 10);
    service = FakeInstallService();
  });

  Future<ProviderContainer> containerWith(
    List<ScriptedResponse> versionResponses, {
    bool supported = true,
    int installedBuild = 2,
  }) async {
    adapter = FakeHttpClientAdapter(script: {'/mobile/app-version': versionResponses});
    final client = await buildFakeApiClient(adapter);
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(client),
      updateSupportedProvider.overrideWithValue(supported),
      updateClockProvider.overrideWithValue(() => now),
      installedVersionProvider.overrideWith((ref) async => InstalledVersion(version: '1.1.0', build: installedBuild)),
      updateInstallServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  UpdateController controllerOf(ProviderContainer c) => c.read(updateControllerProvider.notifier);

  test('iOS/web (desteklenmeyen platform): hiçbir istek atılmaz', () async {
    final c = await containerWith(const [], supported: false);
    final result = await controllerOf(c).check(trigger: UpdateCheckTrigger.startup);
    expect(result.status, UpdateCheckStatus.unsupported);
    expect(result.shouldPrompt, isFalse);
    expect(adapter.calls, isEmpty);
  });

  test('sunucuda sürüm yok (build 0) -> güncel; ?platform=android ile sorulur', () async {
    final c = await containerWith([
      (status: 200, body: {'platform': 'android', 'build': 0}),
    ]);
    final result = await controllerOf(c).check(trigger: UpdateCheckTrigger.startup);
    expect(result.status, UpdateCheckStatus.upToDate);
    expect(result.shouldPrompt, isFalse);
    expect(adapter.calls, ['/mobile/app-version']);
    expect(adapter.requestQueries.single, {'platform': 'android'});
  });

  test('sunucudaki build kurulu olana eşitse güncel', () async {
    final c = await containerWith([(status: 200, body: releaseJson(build: 2))]);
    final result = await controllerOf(c).check(trigger: UpdateCheckTrigger.startup);
    expect(result.status, UpdateCheckStatus.upToDate);
  });

  test('daha yeni build -> güncelleme var, zorunlu değil', () async {
    final c = await containerWith([(status: 200, body: releaseJson(build: 3))]);
    final result = await controllerOf(c).check(trigger: UpdateCheckTrigger.startup);
    expect(result.status, UpdateCheckStatus.available);
    expect(result.mandatory, isFalse);
    expect(result.shouldPrompt, isTrue);
    expect(result.release!.sha256, kSha);
    expect(result.installed!.build, 2);
  });

  test('kurulu build < min_build -> zorunlu', () async {
    final c = await containerWith([(status: 200, body: releaseJson(build: 3, minBuild: 3))]);
    final result = await controllerOf(c).check(trigger: UpdateCheckTrigger.startup);
    expect(result.status, UpdateCheckStatus.available);
    expect(result.mandatory, isTrue);
    expect(c.read(updateControllerProvider).hasMandatoryUpdate, isTrue);
    expect(controllerOf(c).cachedAvailable!.mandatory, isTrue);
  });

  group('"Sonra" ertelemesi', () {
    test('ertelenen build otomatik denetimde sorulmaz, elle denetimde sorulur', () async {
      final c = await containerWith([
        (status: 200, body: releaseJson(build: 3)),
        (status: 200, body: releaseJson(build: 3)),
        (status: 200, body: releaseJson(build: 3)),
      ]);
      final controller = controllerOf(c);
      final first = await controller.check(trigger: UpdateCheckTrigger.startup);
      await controller.postpone(first.release!);

      final auto = await controller.check(trigger: UpdateCheckTrigger.resume);
      expect(auto.status, UpdateCheckStatus.available);
      expect(auto.postponed, isTrue);
      expect(auto.shouldPrompt, isFalse);

      final manual = await controller.check(trigger: UpdateCheckTrigger.manual);
      expect(manual.postponed, isFalse);
      expect(manual.shouldPrompt, isTrue);
    });

    test('24 saat dolunca yine sorulur; daha yeni bir build hemen sorulur', () async {
      final c = await containerWith([
        (status: 200, body: releaseJson(build: 3)),
        (status: 200, body: releaseJson(build: 3)),
        (status: 200, body: releaseJson(build: 4)),
      ]);
      final controller = controllerOf(c);
      await controller.postpone((await controller.check(trigger: UpdateCheckTrigger.startup)).release!);

      now = now.add(const Duration(hours: 24));
      expect((await controller.check(trigger: UpdateCheckTrigger.resume)).shouldPrompt, isTrue);

      now = now.subtract(const Duration(hours: 1));
      expect((await controller.check(trigger: UpdateCheckTrigger.resume)).shouldPrompt, isTrue,
          reason: 'build 4 ertelenmedi');
    });

    test('zorunlu güncelleme ertelemeyi dinlemez', () async {
      final c = await containerWith([
        (status: 200, body: releaseJson(build: 3, minBuild: 3)),
      ]);
      await controllerOf(c).postpone(AppRelease.fromJson(releaseJson(build: 3)));
      final result = await controllerOf(c).check(trigger: UpdateCheckTrigger.startup);
      expect(result.mandatory, isTrue);
      expect(result.postponed, isFalse);
      expect(result.shouldPrompt, isTrue);
    });
  });

  group('hata ve 6 saatlik yeniden denetim', () {
    test('sunucu hatası SESSİZCE failed döner, son denetim zamanı değişmez', () async {
      final c = await containerWith([
        (status: 500, body: {'error': 'sunucu hatası'}),
      ]);
      final controller = controllerOf(c);
      final result = await controller.check(trigger: UpdateCheckTrigger.startup);
      expect(result.status, UpdateCheckStatus.failed);
      expect(result.shouldPrompt, isFalse);
      expect(c.read(updateControllerProvider).lastCheckedAt, isNull);
      expect(controller.isStale, isTrue, reason: 'başarısız denetim bir sonraki öne gelişte tekrar denenir');
    });

    test('başarılı denetimden sonra 6 saat dolana kadar öne gelişte yeniden sorulmaz', () async {
      final c = await containerWith([(status: 200, body: releaseJson(build: 2))]);
      final controller = controllerOf(c);
      expect(controller.isStale, isTrue);
      await controller.check(trigger: UpdateCheckTrigger.startup);
      expect(controller.isStale, isFalse);

      now = now.add(const Duration(hours: 5, minutes: 59));
      expect(controller.isStale, isFalse);
      now = now.add(const Duration(minutes: 1));
      expect(controller.isStale, isTrue);
    });

    test('aynı anda gelen denetimler tek isteği paylaşır', () async {
      final c = await containerWith([(status: 200, body: releaseJson(build: 3))]);
      final controller = controllerOf(c);
      final results = await Future.wait([
        controller.check(trigger: UpdateCheckTrigger.startup),
        controller.check(trigger: UpdateCheckTrigger.login),
      ]);
      expect(results.every((r) => r.status == UpdateCheckStatus.available), isTrue);
      expect(adapter.calls, ['/mobile/app-version']);
    });
  });

  test('aynı anda tek istem: ikinci tryBeginPresentation reddedilir', () async {
    final c = await containerWith(const []);
    final controller = controllerOf(c);
    expect(controller.tryBeginPresentation(), isTrue);
    expect(controller.tryBeginPresentation(), isFalse);
    controller.endPresentation();
    expect(controller.tryBeginPresentation(), isTrue);
  });
}
