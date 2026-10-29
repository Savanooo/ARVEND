import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/push/push_watcher.dart' show rootScaffoldMessengerKey;
import 'package:arvend/core/widgets/app_buttons.dart';
import 'package:arvend/features/ai_images/data/ai_images_providers.dart';
import 'package:arvend/features/ai_images/domain/ai_image.dart';
import 'package:arvend/features/ai_images/presentation/ai_badge.dart';
import 'package:arvend/features/ai_images/presentation/ai_image_job_watcher.dart';
import 'package:arvend/features/ai_images/presentation/ai_image_sheet.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/presentation/project_detail_screen.dart';
import 'package:arvend/features/projects/presentation/project_photo_gallery.dart';

import '../../test_utils/fake_api_client.dart';
import '../contract_co/contract_co_test_support.dart' as cc;

/// Yapay zekâ görselleri (backend migration 0079): girişler yalnızca izin +
/// sunucu açıkken görünür; ilk kullanımda bilgilendirme; iş açılınca
/// "Hazırlanıyor…", sayfa kapansa da sorulmaya devam eder, bitince "Görsel
/// hazır · Göster"; üretilmiş görsel ızgarada ve galeride rozetli.

User _user({bool ai = true}) => User.fromJson({
      'id': 'u1',
      'organization_id': 'org1',
      'username': 'sahip',
      'full_name': 'Firma Sahibi',
      'role': 'admin',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'permissions': [
        'projects.read',
        'projects.tasks.read',
        'projects.operations.read',
        'projects.operations.manage',
        if (ai) kAiImagesPermission,
      ],
    });

Map<String, dynamic> _photo(String id, {String stage = 'progress', Map<String, dynamic>? ai}) => {
      'id': id,
      'original_name': '$id.jpg',
      'mime_type': 'image/jpeg',
      'size_bytes': 2048,
      'stage': stage,
      'description': ai == null ? 'Salon' : 'Bitmiş hali (yapay zekâ görseli): Alçıpan asma tavan',
      'created_at': '2026-10-20T09:00:00Z',
      'ai_generated': ai != null,
      'ai': ai,
    };

const _aiInfo = {
  'kind': 'before_after',
  'prompt': 'Alçıpan asma tavan',
  'source_photo_id': 'ph1',
  'source_date': '2026-10-01T09:00:00Z',
};

Map<String, dynamic> _status({bool enabled = true, int remaining = 97, List<Map<String, dynamic>>? usage}) => {
      'enabled': enabled,
      'can_use': true,
      'quota': {
        'monthly_limit': 100,
        'used_this_month': 100 - remaining,
        'remaining': remaining,
        'user_hourly_limit': 10,
        'resets_at': '2026-11-01T00:00:00+03:00',
      },
      'usage_by_user': ?usage,
    };

Map<String, dynamic> _job(String status, {String kind = 'before_after', String error = '', String? result}) => {
      'id': 'j1',
      'project_id': 'p1',
      'kind': kind,
      'prompt': 'Alçıpan asma tavan, spot ışıklı',
      'source_photo_id': 'ph1',
      'status': status,
      'error': error,
      'result_photo_id': result,
      'model': 'gpt-image-2.5-sunburst',
      'created_at': '2026-10-29T10:00:00Z',
      'started_at': null,
      'finished_at': null,
    };

const _jpeg = <int>[0xFF, 0xD8, 0xFF, 0xE0];

List<ScriptedResponse> _many(Object? body, {int status = 200, int n = 8}) =>
    [for (var i = 0; i < n; i++) (status: status, body: body)];

/// Süresiz ilerleme çubuğu varken pumpAndSettle bitmez: adım adım ilerlet.
Future<void> _advance(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 100);
  for (var t = Duration.zero; t < total; t += step) {
    await tester.pump(step);
  }
}

final _navKey = GlobalKey<NavigatorState>();

Future<FakeHttpClientAdapter> _pumpGallery(
  WidgetTester tester, {
  required List<Map<String, dynamic>> photos,
  User? user,
  bool canUseAi = true,
  Map<String, dynamic>? status,
  Map<String, List<ScriptedResponse>> extra = const {},
}) async {
  final adapter = FakeHttpClientAdapter(script: {
    for (final p in photos) '/projects/p1/photos/${p['id']}/content': _many(_jpeg),
    '/ai/status': _many(status ?? _status()),
    ...extra,
  });
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(const Size(400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final list = photos.map(ProjectPhoto.fromJson).toList();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(client),
      authControllerProvider.overrideWith(() => cc.FakeAuth(user ?? _user())),
      projectPhotoCacheProvider.overrideWithValue(ProjectPhotoCache(directory: () async => null)),
    ],
    child: MaterialApp(
      navigatorKey: _navKey,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      builder: (context, child) => AiImageJobWatcher(navigatorKey: _navKey, child: child!),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showProjectPhotoGallery(
                context,
                projectId: 'p1',
                photos: list,
                canDelete: true,
                canUseAi: canUseAi,
              ),
              child: const Text('Aç'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Aç'));
  await tester.pumpAndSettle();
  return adapter;
}

final _aiButton = find.byTooltip('Yapay zekâ');

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('fotoğraf ve durum yanıtları ayrıştırılır', () {
    final ai = ProjectPhoto.fromJson(_photo('ai1', stage: 'after', ai: _aiInfo));
    expect(ai.isAiGenerated, isTrue);
    expect(ai.ai!.sourcePhotoId, 'ph1');
    expect(aiCaption(ai.ai!), 'Yapay zekâ ile üretildi · kaynak: 01.10.2026');
    expect(aiCaption(const ProjectPhotoAi(kind: 'generate', prompt: 'x')), 'Yapay zekâ ile üretildi');
    expect(ProjectPhoto.fromJson(_photo('ph1')).isAiGenerated, isFalse);
    // Eski yanıtta yalnızca ai_generated gelirse rozet yine çıkar.
    expect(ProjectPhoto.fromJson({..._photo('x'), 'ai_generated': true, 'ai': null}).isAiGenerated, isTrue);

    final st = AiImageStatus.fromJson(_status(usage: [
      {'user_id': 'u1', 'full_name': 'Firma Sahibi', 'images': 3},
    ]));
    expect(st.available, isTrue);
    expect(st.quota!.remaining, 97);
    expect(st.usageByUser!.single.images, 3);
    expect(AiImageStatus.fromJson({'enabled': false, 'can_use': true, 'quota': null}).available, isFalse);
  });

  group('girişler', () {
    testWidgets('izin yoksa durum sorulmaz, düğme yok', (tester) async {
      final adapter = await _pumpGallery(tester, photos: [_photo('ph1')], user: _user(ai: false));
      expect(_aiButton, findsNothing);
      expect(adapter.calls, isNot(contains('/ai/status')));
    });

    testWidgets('sunucuda anahtar yoksa düğme yok', (tester) async {
      await _pumpGallery(tester, photos: [_photo('ph1')], status: _status(enabled: false));
      expect(_aiButton, findsNothing);
    });

    testWidgets('günlük rapor bağlamında (canUseAi=false) düğme yok, durum sorulmaz', (tester) async {
      final adapter = await _pumpGallery(tester, photos: [_photo('ph1')], canUseAi: false);
      expect(_aiButton, findsNothing);
      expect(adapter.calls, isNot(contains('/ai/status')));
    });

    testWidgets('üretilmiş görsel galeride rozet ve kaynak tarihiyle', (tester) async {
      await _pumpGallery(tester, photos: [_photo('ai1', stage: 'after', ai: _aiInfo)], user: _user(ai: false));
      expect(find.byType(AiBadge), findsOneWidget);
      expect(find.text('Yapay zekâ ile üretildi · kaynak: 01.10.2026'), findsOneWidget);
      // Paylaşım ve silme normal fotoğraf gibi.
      expect(find.byTooltip('Fotoğrafı paylaş'), findsOneWidget);
      expect(find.byTooltip('Fotoğrafı sil'), findsOneWidget);
    });
  });

  testWidgets(
      'bitmiş hali: örnek, ilk kullanım bilgisi, Hazırlanıyor…, sayfa kapansa da sorulur, Görsel hazır · Göster',
      (tester) async {
    final adapter = await _pumpGallery(tester, photos: [_photo('ph1')], extra: {
      '/projects/p1/ai-image-jobs': [
        (status: 200, body: {'jobs': <dynamic>[]}), // sayfa açılışı: süren iş var mı
        (status: 202, body: {'job': _job('queued'), 'quota': _status(remaining: 96)['quota']}),
      ],
      '/projects/p1/ai-image-jobs/j1': [
        (status: 200, body: _job('running')),
        (status: 200, body: _job('done', result: 'ai1')),
      ],
      '/projects/p1/photos': _many({
        'photos': [_photo('ph1'), _photo('ai1', stage: 'after', ai: _aiInfo)],
      }),
      '/projects/p1/photos/ai1/content': _many(_jpeg),
    });

    await tester.tap(_aiButton);
    await tester.pumpAndSettle();
    expect(find.text('Bitmiş halini göster'), findsNWidgets(2)); // başlık + düğme
    expect(find.text('Fotoğrafı iyileştir'), findsNWidgets(2));
    for (final example in kAiBeforeAfterExamples.take(3)) {
      expect(find.widgetWithText(ActionChip, example), findsOneWidget);
    }
    expect(find.text('Bu ay kalan: 97 / 100 görsel'), findsOneWidget);
    // Açıklama yazılmadan gönderilemez.
    expect(tester.widget<PrimaryButton>(find.widgetWithText(PrimaryButton, 'Bitmiş halini göster')).onPressed, isNull);

    await tester.tap(find.widgetWithText(ActionChip, 'Alçıpan asma tavan, spot ışıklı'));
    await tester.pump();
    await tester.tap(find.widgetWithText(PrimaryButton, 'Bitmiş halini göster'));
    await tester.pumpAndSettle();
    // İlk kullanım: fotoğraf ve metin OpenAI'ye gider, görsel temsilidir.
    expect(find.text(kAiPrivacyNotice), findsOneWidget);
    await tester.tap(find.text('Anladım, devam et'));
    await _advance(tester, const Duration(milliseconds: 500));

    final post = adapter.methods.indexOf('POST');
    expect(post, greaterThanOrEqualTo(0));
    expect(adapter.requestBodies[post], {
      'kind': 'before_after',
      'prompt': 'Alçıpan asma tavan, spot ışıklı',
      'source_photo_id': 'ph1',
    });
    expect(find.text('Bitmiş hali · $kAiPreparingText'), findsOneWidget);
    expect(find.text(kAiLeaveHint), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool(AiConsentStore.keyFor('u1')), isTrue);

    // Sayfa kapatılır; iş sorulmaya devam eder.
    Navigator.of(tester.element(find.text(kAiLeaveHint))).pop();
    await _advance(tester, const Duration(seconds: 7));
    expect(adapter.calls.where((c) => c == '/projects/p1/ai-image-jobs/j1').length, 2);
    // Bant köke bağlı: ScaffoldMessenger onu açık her Scaffold'da gösterir
    // (galeri saydam rota; alttaki ekranın kopyası galerinin arkasında kalır).
    expect(find.text(kAiReadyText), findsWidgets);

    await tester.tap(find.text(kAiShowAction).hitTestable().first);
    await tester.pumpAndSettle();
    // Galeri yeni görselde açılır: rozet ve "kaynak" tarihi.
    expect(find.text('Yapay zekâ ile üretildi · kaynak: 01.10.2026'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('photo-gallery-counter')).last).data, '2 / 2');
  });

  testWidgets('bilgi reddedilirse hiçbir şey gönderilmez; bir kez kabul edilince tekrar sorulmaz', (tester) async {
    final adapter = await _pumpGallery(tester, photos: [_photo('ph1')], extra: {
      '/projects/p1/ai-image-jobs': [
        (status: 200, body: {'jobs': <dynamic>[]}),
        (
          status: 429,
          body: {
            'error': 'Bu ayın yapay zekâ görsel hakkı doldu (100/100). Yeni hak 01.11.2026 tarihinde açılır.',
            'code': 'ai_monthly_limit',
            'remaining': 0,
          },
        ),
      ],
    });
    await tester.tap(_aiButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SecondaryButton, 'Fotoğrafı iyileştir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    expect(adapter.methods, isNot(contains('POST')));

    await SharedPreferences.getInstance().then((p) => p.setBool(AiConsentStore.keyFor('u1'), true));
    await tester.tap(find.widgetWithText(SecondaryButton, 'Fotoğrafı iyileştir'));
    await tester.pumpAndSettle();
    expect(find.text(kAiPrivacyNotice), findsNothing);
    // Sunucunun Türkçe 429 metni olduğu gibi görünür.
    expect(find.text('Bu ayın yapay zekâ görsel hakkı doldu (100/100). Yeni hak 01.11.2026 tarihinde açılır.'),
        findsOneWidget);
  });

  testWidgets('başarısız iş sunucunun Türkçe nedeniyle bant gösterir', (tester) async {
    SharedPreferences.setMockInitialValues({AiConsentStore.keyFor('u1'): true});
    const reason = 'İstek OpenAI\'nin güvenlik kurallarına takıldı. Açıklamayı ya da fotoğrafı değiştirip tekrar deneyin.';
    await _pumpGallery(tester, photos: [_photo('ph1')], extra: {
      '/projects/p1/ai-image-jobs': [
        (status: 200, body: {'jobs': <dynamic>[]}),
        (status: 202, body: {'job': _job('queued', kind: 'enhance')}),
      ],
      '/projects/p1/ai-image-jobs/j1': [(status: 200, body: _job('failed', kind: 'enhance', error: reason))],
    });
    await tester.tap(_aiButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SecondaryButton, 'Fotoğrafı iyileştir'));
    await _advance(tester, const Duration(milliseconds: 500));
    expect(find.text('İyileştirilmiş fotoğraf · $kAiPreparingText'), findsOneWidget);
    await _advance(tester, const Duration(seconds: 4));
    expect(find.text(reason), findsWidgets);
    expect(find.text(kAiPreparingText, findRichText: true), findsNothing);
  });

  group('proje fotoğrafları bölümü', () {
    Future<FakeHttpClientAdapter> pumpFiles(
      WidgetTester tester, {
      required User user,
      required List<Map<String, dynamic>> photos,
      Map<String, List<ScriptedResponse>> extra = const {},
    }) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/photos': _many({'photos': photos}),
        '/projects/p1/files': _many({'files': <dynamic>[]}),
        '/projects/p1/tasks': _many({'tasks': <dynamic>[]}),
        '/projects/p1/operations-summary': _many({
          'open_task_count': 0,
          'completed_task_count': 0,
          'overdue_task_count': 0,
          'active_member_count': 0,
        }),
        '/projects/p1/notes': _many({'notes': <dynamic>[]}),
        '/ai/status': _many(_status()),
        for (final p in photos) '/projects/p1/photos/${p['id']}/content': _many(_jpeg),
        ...extra,
      });
      final client = await buildFakeApiClient(adapter);
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(client),
          authControllerProvider.overrideWith(() => cc.FakeAuth(user)),
          projectDetailProvider.overrideWith((ref, id) async => cc.sampleProject()),
          projectPhotoCacheProvider.overrideWithValue(ProjectPhotoCache(directory: () async => null)),
        ],
        child: const MaterialApp(home: ProjectDetailScreen(projectId: 'p1', initialGroup: 'dokumanlar')),
      ));
      await tester.pumpAndSettle();
      return adapter;
    }

    testWidgets('ızgarada üretilmiş görselin rozeti var; izinsiz kişide oluşturma düğmesi yok', (tester) async {
      await pumpFiles(tester, user: _user(ai: false), photos: [_photo('ph1'), _photo('ai1', stage: 'after', ai: _aiInfo)]);
      expect(find.byKey(const ValueKey('proje-foto-ai1')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('proje-foto-ai1')), matching: find.byType(AiBadge)),
          findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('proje-foto-ph1')), matching: find.byType(AiBadge)),
          findsNothing);
      expect(find.text('Yapay zekâ ile görsel oluştur'), findsNothing);
    });

    testWidgets('yeni görsel: açıklama + isteğe bağlı referans fotoğraf, bölümde Hazırlanıyor…', (tester) async {
      SharedPreferences.setMockInitialValues({AiConsentStore.keyFor('u1'): true});
      final adapter = await pumpFiles(tester, user: _user(), photos: [_photo('ph1')], extra: {
        '/projects/p1/ai-image-jobs': [
          (status: 200, body: {'jobs': <dynamic>[]}),
          (status: 202, body: {'job': _job('queued', kind: 'generate')}),
        ],
        '/projects/p1/ai-image-jobs/j1': [(status: 200, body: _job('done', kind: 'generate', result: 'ai2'))],
      });
      await tester.tap(find.text('Yapay zekâ ile görsel oluştur'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('ai-generate-prompt')), 'Banyo seramik, duşakabin');
      await tester.tap(find.byKey(const ValueKey('ai-reference-ph1')));
      await tester.pump();
      await tester.tap(find.widgetWithText(PrimaryButton, 'Görsel oluştur'));
      await _advance(tester, const Duration(milliseconds: 500));

      final post = adapter.methods.indexOf('POST');
      expect(adapter.requestBodies[post], {
        'kind': 'generate',
        'prompt': 'Banyo seramik, duşakabin',
        'source_photo_id': 'ph1',
      });
      Navigator.of(tester.element(find.text(kAiLeaveHint))).pop();
      await _advance(tester, const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('ai-preparing')), findsOneWidget);
      await _advance(tester, const Duration(seconds: 4));
      // Bitince bölümdeki ilerleme kalkar, fotoğraf listesi tazelenir.
      expect(find.byKey(const ValueKey('ai-preparing')), findsNothing);
      expect(adapter.calls.where((c) => c == '/projects/p1/photos').length, greaterThanOrEqualTo(2));
    });
  });
}
