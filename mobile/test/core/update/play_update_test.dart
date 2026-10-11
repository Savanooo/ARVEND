import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/push/push_watcher.dart' show rootScaffoldMessengerKey;
import 'package:arvend/core/update/app_release.dart';
import 'package:arvend/core/update/play_update.dart';
import 'package:arvend/core/update/update_controller.dart';

import '../../test_utils/fake_api_client.dart';
import 'update_fakes.dart';

class FakePlayClient implements PlayUpdateClient {
  FakePlayClient(this.info, {this.flexible = PlayUpdateOutcome.completed, this.immediate = PlayUpdateOutcome.denied});

  PlayUpdateInfo info;
  Object? checkError;
  PlayUpdateOutcome flexible;
  PlayUpdateOutcome immediate;
  final calls = <String>[];

  @override
  Future<PlayUpdateInfo> check() async {
    calls.add('check');
    if (checkError != null) throw checkError!;
    return info;
  }

  @override
  Future<PlayUpdateOutcome> startFlexible() async {
    calls.add('flexible');
    return flexible;
  }

  @override
  Future<PlayUpdateOutcome> performImmediate() async {
    calls.add('immediate');
    return immediate;
  }

  @override
  Future<void> completeFlexible() async => calls.add('complete');
}

/// Sideload kanalı kapalıyken (latest.json yok) backend'in yanıtı: build 0,
/// Play tabanı play.json'dan.
ScriptedResponse playPolicy(int minBuild) => (status: 200, body: {'platform': 'android', 'build': 0, 'min_build': minBuild});

const _available = PlayUpdateInfo(available: true, immediateAllowed: true, flexibleAllowed: true, versionCode: 14);

void main() {
  late DateTime now;
  late FakeHttpClientAdapter adapter;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    now = DateTime(2026, 10, 6, 10);
  });

  var storeOpens = 0;

  Future<List<Override>> overrides(
    FakePlayClient play, {
    List<ScriptedResponse> version = const [],
    bool supported = true,
    bool storeOpenResult = true,
  }) async {
    adapter = FakeHttpClientAdapter(script: {'/mobile/app-version': version});
    final client = await buildFakeApiClient(adapter);
    storeOpens = 0;
    return [
      apiClientProvider.overrideWithValue(client),
      playUpdateSupportedProvider.overrideWithValue(supported),
      playUpdateClientProvider.overrideWithValue(play),
      updateClockProvider.overrideWithValue(() => now),
      installedVersionProvider.overrideWith((ref) async => const InstalledVersion(version: '1.5.7', build: 13)),
      playStoreOpenerProvider.overrideWithValue(() async {
        storeOpens++;
        return storeOpenResult;
      }),
    ];
  }

  Future<PlayUpdateController> controllerFor(
    FakePlayClient play, {
    List<ScriptedResponse> version = const [],
    bool supported = true,
  }) async {
    final c = ProviderContainer(overrides: await overrides(play, version: version, supported: supported));
    addTearDown(c.dispose);
    return c.read(playUpdateControllerProvider);
  }

  // Sahte adaptör senaryoyu TÜKETİR -- her test kendi listesini alır.
  List<ScriptedResponse> notMandatory([int times = 1]) =>
      [for (var i = 0; i < times; i++) (status: 200, body: releaseJson(build: 14))];
  List<ScriptedResponse> mandatory([int times = 1]) =>
      [for (var i = 0; i < times; i++) (status: 200, body: releaseJson(build: 14, minBuild: 14))];

  test('sideload/iOS yapısında Play\'e hiç sorulmaz', () async {
    final play = FakePlayClient(_available);
    final c = await controllerFor(play, supported: false);
    expect(await c.run(manual: false), PlayUpdateStatus.unsupported);
    expect(play.calls, isEmpty);
  });

  test('Play\'de yeni sürüm yoksa güncel; sunucuya da sorulmaz', () async {
    final play = FakePlayClient(const PlayUpdateInfo());
    final c = await controllerFor(play);
    expect(await c.run(manual: false), PlayUpdateStatus.upToDate);
    expect(play.calls, ['check']);
    expect(adapter.calls, isEmpty);
  });

  test('yeni sürüm, zorunlu değil -> Play penceresi (arka planda indirme), inince kurulmaya hazır', () async {
    final play = FakePlayClient(_available);
    final c = await controllerFor(play, version: notMandatory());
    expect(await c.run(manual: false), PlayUpdateStatus.readyToInstall);
    expect(play.calls, ['check', 'flexible']);
    expect(c.mandatoryPending, isFalse);
  });

  test('reddedilen sürüm 24 saat otomatik sorulmaz, elle denetimde sorulur, daha yeni sürümde yine sorulur', () async {
    final play = FakePlayClient(_available, flexible: PlayUpdateOutcome.denied);
    final c = await controllerFor(play, version: notMandatory(4));
    expect(await c.run(manual: false), PlayUpdateStatus.denied);
    expect(await c.run(manual: false), PlayUpdateStatus.postponed);
    expect(play.calls.where((c) => c == 'flexible'), hasLength(1));

    expect(await c.run(manual: true), PlayUpdateStatus.denied);
    expect(play.calls.where((c) => c == 'flexible'), hasLength(2));

    play.info = const PlayUpdateInfo(available: true, immediateAllowed: true, flexibleAllowed: true, versionCode: 15);
    expect(await c.run(manual: false), PlayUpdateStatus.denied);
    expect(play.calls.where((c) => c == 'flexible'), hasLength(3));
  });

  test('kurulu build < sunucudaki min_build -> tam ekran güncelleme; vazgeçilse de ertelenmez', () async {
    final play = FakePlayClient(_available);
    final c = await controllerFor(play, version: mandatory(2));
    expect(await c.run(manual: false), PlayUpdateStatus.denied);
    expect(play.calls, ['check', 'immediate']);
    expect(c.mandatoryPending, isTrue);
    expect(c.updateRequired, isTrue, reason: 'vazgeçildi: "Güncelleme gerekli" ekranı');

    expect(await c.run(manual: false), PlayUpdateStatus.denied);
    expect(play.calls, ['check', 'immediate', 'check', 'immediate']);
  });

  test('sideload yayını yokken (build 0) de sunucunun min_build tabanı zorunlu sayılır (mobil-genel-b1)', () async {
    final play = FakePlayClient(_available, immediate: PlayUpdateOutcome.completed);
    final c = await controllerFor(play, version: [playPolicy(14)]);
    expect(await c.run(manual: false), PlayUpdateStatus.started);
    expect(play.calls, ['check', 'immediate']);
    expect(c.mandatoryPending, isTrue);
    expect(c.updateRequired, isFalse, reason: 'Play güncellemeyi başlattı');
  });

  test('taban kurulu build\'e eşit/altındaysa zorunlu değil -> esnek öneri', () async {
    final play = FakePlayClient(_available);
    final c = await controllerFor(play, version: [playPolicy(13)]);
    expect(await c.run(manual: false), PlayUpdateStatus.readyToInstall);
    expect(play.calls, ['check', 'flexible']);
    expect(c.updateRequired, isFalse);
  });

  test('sunucu zorunlu dese de Play\'de kurulacak sürüm yoksa kilitlenmez', () async {
    final play = FakePlayClient(const PlayUpdateInfo());
    final c = await controllerFor(play, version: [playPolicy(99)]);
    expect(await c.run(manual: false), PlayUpdateStatus.upToDate);
    expect(c.updateRequired, isFalse);
    expect(c.mandatoryPending, isFalse);
  });

  test('zorunlu, tam ekrana izin yok: arka planda iner ve hemen kurulur', () async {
    final play = FakePlayClient(
      const PlayUpdateInfo(available: true, flexibleAllowed: true, versionCode: 14),
    );
    final c = await controllerFor(play, version: mandatory());
    expect(await c.run(manual: false), PlayUpdateStatus.started);
    expect(play.calls, ['check', 'flexible', 'complete']);
    expect(c.updateRequired, isFalse);
  });

  test('zorunlu ekrandayken Play\'e ulaşılamazsa ekran kalkar (uygulama kilitlenmez)', () async {
    final play = FakePlayClient(_available);
    final c = await controllerFor(play, version: mandatory());
    await c.run(manual: false);
    expect(c.updateRequired, isTrue);

    play.checkError = Exception('Install Error(-10)');
    expect(await c.run(manual: true), PlayUpdateStatus.failed);
    expect(c.updateRequired, isFalse);
  });

  test('esnek öneri günde en fazla bir kez: pencere açıldıysa (yarıda kalsa da) aynı gün yeniden açılmaz', () async {
    final play = FakePlayClient(_available, flexible: PlayUpdateOutcome.failed);
    final c = await controllerFor(play, version: notMandatory(4));
    expect(await c.run(manual: false), PlayUpdateStatus.failed);
    now = now.add(const Duration(hours: 7));
    expect(await c.run(manual: false), PlayUpdateStatus.postponed);
    expect(play.calls.where((c) => c == 'flexible'), hasLength(1));

    // Elle denetim ertelemeye bakmaz.
    expect(await c.run(manual: true), PlayUpdateStatus.failed);
    expect(play.calls.where((c) => c == 'flexible'), hasLength(2));

    // Ertesi gün yeniden önerilir.
    now = now.add(const Duration(hours: 18));
    expect(await c.run(manual: false), PlayUpdateStatus.failed);
    expect(play.calls.where((c) => c == 'flexible'), hasLength(3));
  });

  test('yarım kalan zorunlu güncelleme sürdürülür', () async {
    final play = FakePlayClient(const PlayUpdateInfo(inProgress: true, versionCode: 14),
        immediate: PlayUpdateOutcome.completed);
    final c = await controllerFor(play, version: mandatory());
    expect(await c.run(manual: false), PlayUpdateStatus.started);
    expect(play.calls, ['check', 'immediate']);
  });

  test('sunucuya ulaşılamazsa zorunlu SAYILMAZ -- kullanıcı kilitlenmez', () async {
    final play = FakePlayClient(_available);
    final c = await controllerFor(play, version: [(status: 500, body: {'error': 'x'})]);
    expect(await c.run(manual: false), PlayUpdateStatus.readyToInstall);
    expect(play.calls, ['check', 'flexible']);
  });

  test('indirme bitmişse pencere açılmadan kurulmaya hazır', () async {
    final play = FakePlayClient(const PlayUpdateInfo(downloaded: true, inProgress: true));
    final c = await controllerFor(play);
    expect(await c.run(manual: false), PlayUpdateStatus.readyToInstall);
    expect(play.calls, ['check']);
  });

  test('Play\'e ulaşılamazsa (ör. Play\'den kurulmamış) sessizce başarısız', () async {
    final play = FakePlayClient(_available)..checkError = Exception('Install Error(-10)');
    final c = await controllerFor(play);
    expect(await c.run(manual: true), PlayUpdateStatus.failed);
  });

  test('elle denetimde kilit Play penceresi açılmadan çözülür', () async {
    final play = FakePlayClient(_available);
    final c = await controllerFor(play, version: notMandatory());
    final events = <String>[];
    await c.run(manual: true, onChecked: () => events.add('checked:${play.calls.length}'));
    // İlk onChecked çağrısı 'flexible'dan ÖNCE (yalnızca 'check' varken).
    expect(events.first, 'checked:1');
  });

  testWidgets('açılışta indirme bitmişse "Yeniden başlat" çubuğu çıkar ve kurar', (tester) async {
    final play = FakePlayClient(const PlayUpdateInfo(downloaded: true));
    await tester.pumpWidget(ProviderScope(
      overrides: await overrides(play),
      child: MaterialApp(
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        home: const PlayUpdateWatcher(child: Scaffold(body: Text('ana'))),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text(kPlayUpdateReadyMessage), findsOneWidget);
    await tester.tap(find.text(kPlayUpdateRestartLabel));
    await tester.pump();
    expect(play.calls, ['check', 'complete']);
  });

  group('"Güncelleme gerekli" ekranı', () {
    Future<void> pumpWatcher(WidgetTester tester, FakePlayClient play, List<ScriptedResponse> version,
        {bool storeOpenResult = true}) async {
      await tester.pumpWidget(ProviderScope(
        overrides: await overrides(play, version: version, storeOpenResult: storeOpenResult),
        child: MaterialApp(
          scaffoldMessengerKey: rootScaffoldMessengerKey,
          builder: (context, child) => PlayUpdateWatcher(child: child!),
          home: const Scaffold(body: Text('ana')),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('zorunlu güncellemeden vazgeçilince uygulamanın yerine kapatılamayan ekran çıkar', (tester) async {
      final play = FakePlayClient(_available);
      await pumpWatcher(tester, play, mandatory(3));

      expect(find.text(kPlayUpdateRequiredTitle), findsOneWidget);
      expect(find.text(kPlayUpdateRequiredMessage), findsOneWidget);
      expect(find.text('ana'), findsNothing, reason: 'uygulama arkada, görünmez');
      expect(find.text('Kurulu sürüm: 1.5.7 (13)'), findsOneWidget);

      // Geri tuşu ekranı kapatmaz; uygulama arka plana alınır.
      final platformCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call.method);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text(kPlayUpdateRequiredTitle), findsOneWidget);
      expect(platformCalls, contains('SystemNavigator.pop'));

      // "Güncelle": Play'in tam ekran güncellemesi yeniden açılır; başlarsa ekran kalkar.
      play.immediate = PlayUpdateOutcome.completed;
      await tester.tap(find.text(kPlayUpdateRequiredUpdateLabel));
      await tester.pumpAndSettle();
      expect(play.calls, ['check', 'immediate', 'check', 'immediate']);
      expect(find.text(kPlayUpdateRequiredTitle), findsNothing);
      expect(find.text('ana'), findsOneWidget);
    });

    testWidgets('"Google Play\'de aç" Play sayfasını açar; açılamazsa ne yapacağı söylenir', (tester) async {
      final play = FakePlayClient(_available, immediate: PlayUpdateOutcome.failed);
      await pumpWatcher(tester, play, mandatory(), storeOpenResult: false);
      expect(find.text(kPlayUpdateRequiredTitle), findsOneWidget, reason: 'pencere açılamadı -> ekran');

      await tester.tap(find.text(kPlayUpdateRequiredStoreLabel));
      await tester.pumpAndSettle();
      expect(storeOpens, 1);
      expect(find.text(kPlayStoreOpenFailedMessage), findsOneWidget);
    });

    testWidgets('zorunlu değilse ekran hiç çıkmaz', (tester) async {
      final play = FakePlayClient(_available, flexible: PlayUpdateOutcome.denied);
      await pumpWatcher(tester, play, notMandatory());
      expect(find.text(kPlayUpdateRequiredTitle), findsNothing);
      expect(find.text('ana'), findsOneWidget);
    });

    testWidgets('Play\'e ulaşılamazsa (Play dışı kurulum) ekran çıkmaz', (tester) async {
      final play = FakePlayClient(_available)..checkError = Exception('Install Error(-10)');
      await pumpWatcher(tester, play, mandatory());
      expect(find.text(kPlayUpdateRequiredTitle), findsNothing);
      expect(find.text('ana'), findsOneWidget);
    });
  });

  testWidgets('desteklenmeyen yapıda izleyici hiçbir şey yapmaz', (tester) async {
    final play = FakePlayClient(const PlayUpdateInfo(downloaded: true));
    await tester.pumpWidget(ProviderScope(
      overrides: await overrides(play, supported: false),
      child: MaterialApp(
        scaffoldMessengerKey: rootScaffoldMessengerKey,
        home: const PlayUpdateWatcher(child: Scaffold(body: Text('ana'))),
      ),
    ));
    await tester.pumpAndSettle();
    expect(play.calls, isEmpty);
    expect(find.text(kPlayUpdateReadyMessage), findsNothing);
  });
}
