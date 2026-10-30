import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show ImageSource;
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/files/device_picker.dart';
import 'package:arvend/core/files/file_share.dart';
import 'package:arvend/core/push/push_watcher.dart' show rootScaffoldMessengerKey;
import 'package:arvend/core/widgets/app_buttons.dart';
import 'package:arvend/features/ai_images/data/ai_images_providers.dart';
import 'package:arvend/features/ai_images/data/ai_images_repository.dart';
import 'package:arvend/features/ai_images/data/ai_mask.dart';
import 'package:arvend/features/ai_images/data/ai_studio_repository.dart';
import 'package:arvend/features/ai_images/domain/ai_image.dart';
import 'package:arvend/features/ai_images/domain/ai_studio.dart';
import 'package:arvend/features/ai_images/presentation/ai_image_job_watcher.dart';
import 'package:arvend/features/ai_images/presentation/ai_image_sheet.dart';
import 'package:arvend/features/ai_images/presentation/ai_mask_editor.dart';
import 'package:arvend/features/ai_images/presentation/ai_studio_screen.dart';
import 'package:arvend/features/ai_images/presentation/ai_studio_viewer.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/profile/presentation/other_menu_screen.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';

import '../../test_utils/fake_api_client.dart';
import '../../test_utils/fake_file_sharer.dart';
import '../contract_co/contract_co_test_support.dart' as cc;

/// Yapay Zekâ Stüdyo: projeden bağımsız görsel oluşturma / fotoğraf
/// düzenleme, Görsellerim, görüntüleyici (Düzenle, Projeye ekle, Sil) ve
/// "Alanı işaretle" maskesi.

User _user({bool ai = true, String roleCode = 'owner'}) => User.fromJson({
      'id': 'u1',
      'organization_id': 'org1',
      'username': 'sahip',
      'full_name': 'Firma Sahibi',
      'role': 'admin',
      'organization_role_code': roleCode,
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'permissions': [
        'projects.read',
        'projects.operations.read',
        'projects.operations.manage',
        'projects.expenses.create',
        if (ai) kAiImagesPermission,
      ],
    });

Map<String, dynamic> _status({bool enabled = true, int remaining = 97}) => {
      'enabled': enabled,
      'can_use': true,
      'quota': {
        'monthly_limit': 100,
        'used_this_month': 100 - remaining,
        'remaining': remaining,
        'user_hourly_limit': 10,
        'resets_at': '2026-11-01T00:00:00+03:00',
      },
    };

Map<String, dynamic> _job(String status, {String id = 'j1', String kind = 'generate', String? image}) => {
      'id': id,
      'kind': kind,
      'status': status,
      'error': null,
      'prompt': 'Modern salon',
      'studio_image_id': image,
      'created_at': '2026-10-30T10:00:00Z',
    };

Map<String, dynamic> _image(String id, {String kind = 'generate', List<Map<String, dynamic>> projects = const []}) => {
      'id': id,
      'kind': kind,
      'prompt': 'Modern salon, ahşap parke',
      'created_at': '2026-10-30T10:01:00Z',
      'user_id': 'u1',
      'user_name': 'Firma Sahibi',
      'mime': 'image/jpeg',
      'size_bytes': 1024,
      'projects': projects,
    };

Map<String, dynamic> _page(List<Map<String, dynamic>> images, {List<Map<String, dynamic>> pending = const [], String? next}) =>
    {'images': images, 'pending_jobs': pending, 'next_before': next};

const _jpeg = <int>[0xFF, 0xD8, 0xFF, 0xE0];

List<ScriptedResponse> _many(Object? body, {int status = 200, int n = 8}) =>
    [for (var i = 0; i < n; i++) (status: status, body: body)];

/// pumpAndSettle yerine: "Hazırlanıyor…" göstergesi varken o hiç bitmez.
Future<void> _settle(WidgetTester tester) => _advance(tester, const Duration(milliseconds: 700));

Future<void> _advance(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 100);
  for (var t = Duration.zero; t < total; t += step) {
    await tester.pump(step);
  }
}

class _FakePicker implements DevicePicker {
  _FakePicker(this.path);
  final String path;

  @override
  Future<PickedDeviceFile?> pickImage(ImageSource source) async => (path: path, name: 'salon.jpg', size: 4);

  @override
  Future<PickedDeviceFile?> pickFile() async => null;
}

final _navKey = GlobalKey<NavigatorState>();

late String _photoPath;

Future<FakeHttpClientAdapter> _pumpStudio(
  WidgetTester tester, {
  User? user,
  Map<String, List<ScriptedResponse>> script = const {},
  Size size = const Size(400, 900),
  double textScale = 1,
  FakeFileSharer? sharer,
}) async {
  final adapter = FakeHttpClientAdapter(script: {
    '/ai/status': _many(_status(), n: 20),
    ...script,
  });
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    // Aynı testte ikinci kez kurulunca eski kapsam (eski kullanıcı) kalmasın.
    key: UniqueKey(),
    overrides: [
      apiClientProvider.overrideWithValue(client),
      authControllerProvider.overrideWith(() => cc.FakeAuth(user ?? _user())),
      projectPhotoCacheProvider.overrideWithValue(ProjectPhotoCache(directory: () async => null)),
      devicePickerProvider.overrideWithValue(_FakePicker(_photoPath)),
      fileSharerProvider.overrideWithValue(sharer ?? FakeFileSharer()),
    ],
    child: MaterialApp(
      navigatorKey: _navKey,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: AiImageJobWatcher(navigatorKey: _navKey, child: child!),
      ),
      home: const AiStudioScreen(),
    ),
  ));
  // pumpAndSettle değil: "Hazırlanıyor…" kutucuğunun göstergesi hiç durmaz.
  await _advance(tester, const Duration(milliseconds: 500));
  return adapter;
}

/// Gönderilen multipart: alanlar ve dosya parça adları.
({Map<String, String> fields, List<String> files}) _form(FakeHttpClientAdapter adapter, String path, {int nth = 0}) {
  final indexes = [
    for (var i = 0; i < adapter.calls.length; i++)
      if (adapter.calls[i] == path && adapter.methods[i] == 'POST') i,
  ];
  final form = adapter.requestBodies[indexes[nth]] as FormData;
  return (
    fields: {for (final f in form.fields) f.key: f.value},
    files: [for (final f in form.files) f.key],
  );
}

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = Colors.brown);
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// PNG'yi çözüp ([x],[y]) pikselinin alfasını ve boyutu döndürür.
Future<({int width, int height, int Function(int x, int y) alpha})> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final w = image.width;
  return (width: w, height: image.height, alpha: (int x, int y) => rgba.getUint8((y * w + x) * 4 + 3));
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    final dir = Directory.systemTemp.createTempSync('ai_studio_test');
    _photoPath = '${dir.path}/salon.jpg';
    File(_photoPath).writeAsBytesSync(_jpeg);
  });
  setUp(() => SharedPreferences.setMockInitialValues({AiConsentStore.keyFor('u1'): true}));

  group('giriş', () {
    Future<FakeHttpClientAdapter> pumpMenu(WidgetTester tester, User user, {bool enabled = true}) async {
      final adapter = FakeHttpClientAdapter(script: {'/ai/status': _many(_status(enabled: enabled))});
      final client = await buildFakeApiClient(adapter);
      await tester.binding.setSurfaceSize(const Size(360, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ProviderScope(
        key: UniqueKey(),
        overrides: [
          apiClientProvider.overrideWithValue(client),
          authControllerProvider.overrideWith(() => cc.FakeAuth(user)),
        ],
        child: const MaterialApp(home: OtherMenuScreen()),
      ));
      // Sahte istek zamanlayıcıyla döner: sahte saati ilerlet.
      await _advance(tester, const Duration(milliseconds: 500));
      return adapter;
    }

    testWidgets('izin + sunucu açık: Diğer > İş Araçları\'nın en üstünde', (tester) async {
      await pumpMenu(tester, _user());
      expect(find.text(kAiStudioTitle), findsOneWidget);
      final studioY = tester.getTopLeft(find.text(kAiStudioTitle)).dy;
      expect(studioY, lessThan(tester.getTopLeft(find.text('Masraflar')).dy));
      expect(studioY, greaterThan(tester.getTopLeft(find.text('İş Araçları')).dy));
    });

    testWidgets('izin yoksa durum hiç sorulmaz, giriş yok; sunucu kapalıysa giriş yok', (tester) async {
      final adapter = await pumpMenu(tester, _user(ai: false));
      expect(find.text(kAiStudioTitle), findsNothing);
      expect(adapter.calls, isNot(contains('/ai/status')));

      await pumpMenu(tester, _user(), enabled: false);
      expect(find.text(kAiStudioTitle), findsNothing);
    });
  });

  testWidgets('yeni görsel: multipart kind+prompt, Hazırlanıyor… kutucuğu, bitince Görsellerim ve Göster', (tester) async {
    final adapter = await _pumpStudio(tester, script: {
      '/ai/studio/images': [
        (status: 200, body: _page([])),
        ..._many(_page([_image('s1')])),
      ],
      '/ai/studio/jobs': [(status: 202, body: {'job': _job('queued'), 'remaining': 96, 'limit': 100})],
      '/ai/studio/jobs/j1': [(status: 200, body: _job('done', image: 's1'))],
      '/ai/studio/images/s1/content': _many(_jpeg),
    });
    expect(find.text('Bu ay kalan: 97 / 100 görsel'), findsOneWidget);
    expect(find.textContaining('Henüz görsel yok'), findsOneWidget);
    // Firma sahibi kapsam seçicisini görür; ilk istek kendi görselleri.
    expect(find.byKey(const ValueKey('ai-studio-scope')), findsOneWidget);
    expect(adapter.requestQueries[adapter.calls.indexOf('/ai/studio/images')]['scope'], 'mine');

    await tester.tap(find.byKey(const ValueKey('ai-studio-generate')));
    await _settle(tester);
    for (final example in kAiGenerateExamples) {
      expect(find.widgetWithText(ActionChip, example), findsOneWidget);
    }
    await tester.enterText(find.byKey(const ValueKey('ai-studio-generate-prompt')), 'Modern salon');
    await tester.pump();
    await tester.tap(find.widgetWithText(PrimaryButton, 'Görsel oluştur'));
    await _advance(tester, const Duration(milliseconds: 600));

    final sent = _form(adapter, '/ai/studio/jobs');
    expect(sent.fields, {'kind': 'generate', 'prompt': 'Modern salon'});
    expect(sent.files, isEmpty);
    // Sayfa kapandı; ızgarada süren iş.
    expect(find.byKey(const ValueKey('ai-studio-pending-j1')), findsOneWidget);
    expect(find.text(kAiPreparingText), findsOneWidget);

    await _advance(tester, const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('ai-studio-pending-j1')), findsNothing);
    expect(find.byKey(const ValueKey('ai-studio-image-s1')), findsOneWidget);
    expect(find.text(kAiReadyText), findsWidgets);

    await tester.tap(find.text(kAiShowAction).hitTestable().first);
    await _advance(tester, const Duration(milliseconds: 600));
    expect(find.byType(AiStudioViewer), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('ai-studio-viewer-counter'))).data, '1 / 1');
    expect(find.text('Modern salon, ahşap parke'), findsOneWidget);
  });

  group('fotoğraf yükle ve düzenle', () {
    Future<FakeHttpClientAdapter> openEdit(WidgetTester tester) async {
      final adapter = await _pumpStudio(tester, script: {
        '/ai/studio/images': _many(_page([])),
        '/ai/studio/jobs': _many({'job': _job('queued', kind: 'edit'), 'remaining': 96, 'limit': 100}, status: 202),
        '/ai/studio/jobs/j1': _many(_job('running')),
      });
      await tester.tap(find.byKey(const ValueKey('ai-studio-upload')));
      await _settle(tester);
      await tester.tap(find.text('Galeriden seç'));
      await _settle(tester);
      expect(find.text('Fotoğrafı düzenle'), findsOneWidget);
      return adapter;
    }

    testWidgets('bitmiş hali: üç örnek, image dosyası + kind/prompt', (tester) async {
      final adapter = await openEdit(tester);
      for (final example in kAiBeforeAfterExamples.take(3)) {
        expect(find.widgetWithText(ActionChip, example), findsOneWidget);
      }
      expect(tester.widget<PrimaryButton>(find.widgetWithText(PrimaryButton, 'Bitmiş halini göster')).onPressed, isNull);
      await tester.tap(find.widgetWithText(ActionChip, 'Banyo seramik, duşakabin'));
      await tester.pump();
      await tester.tap(find.widgetWithText(PrimaryButton, 'Bitmiş halini göster'));
      await _advance(tester, const Duration(milliseconds: 600));
      final sent = _form(adapter, '/ai/studio/jobs');
      expect(sent.fields, {'kind': 'before_after', 'prompt': 'Banyo seramik, duşakabin'});
      expect(sent.files, ['image']);
    });

    testWidgets('iyileştir: açıklamasız; Kendin yaz: edit + talimat, işaretlenmemişse maske yok', (tester) async {
      final adapter = await openEdit(tester);
      await tester.tap(find.byKey(const ValueKey('ai-studio-mode-enhance')));
      await tester.pump();
      expect(find.byKey(const ValueKey('ai-studio-edit-prompt')), findsNothing);
      await tester.tap(find.widgetWithText(PrimaryButton, 'Fotoğrafı iyileştir'));
      await _advance(tester, const Duration(milliseconds: 600));
      var sent = _form(adapter, '/ai/studio/jobs');
      expect(sent.fields, {'kind': 'enhance'});
      expect(sent.files, ['image']);

      await tester.tap(find.byKey(const ValueKey('ai-studio-upload')));
      await _settle(tester);
      await tester.tap(find.text('Fotoğraf çek'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('ai-studio-mode-custom')));
      await tester.pump();
      for (final example in kAiEditExamples) {
        expect(find.widgetWithText(ActionChip, example), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('ai-mask-open')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('ai-studio-edit-prompt')), 'Duvarı griye boya');
      await tester.pump();
      await tester.tap(find.widgetWithText(PrimaryButton, 'Görseli düzenle'));
      await _advance(tester, const Duration(milliseconds: 600));
      sent = _form(adapter, '/ai/studio/jobs', nth: 1);
      expect(sent.fields, {'kind': 'edit', 'prompt': 'Duvarı griye boya'});
      expect(sent.files, ['image']);
    });
  });

  testWidgets('429: sunucunun Türkçe metni sayfada, hak satırı tazelenir', (tester) async {
    const msg = 'Bu ayın yapay zekâ görsel hakkı doldu (100/100). Yeni hak 01.11.2026 tarihinde açılır.';
    final adapter = await _pumpStudio(tester, script: {
      '/ai/studio/images': _many(_page([])),
      '/ai/studio/jobs': [
        (status: 429, body: {'error': msg, 'code': 'ai_monthly_limit', 'remaining': 0}),
      ],
    });
    final statusCalls = adapter.calls.where((c) => c == '/ai/status').length;
    await tester.tap(find.byKey(const ValueKey('ai-studio-generate')));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('ai-studio-generate-prompt')), 'Modern salon');
    await tester.pump();
    await tester.tap(find.widgetWithText(PrimaryButton, 'Görsel oluştur'));
    await _settle(tester);
    expect(find.text(msg), findsOneWidget);
    expect(adapter.calls.where((c) => c == '/ai/status').length, greaterThan(statusCalls));
  });

  group('görüntüleyici', () {
    Future<FakeHttpClientAdapter> openViewer(WidgetTester tester, Map<String, List<ScriptedResponse>> extra) async {
      final adapter = await _pumpStudio(tester, script: {
        '/ai/studio/images': _many(_page([_image('s1')], pending: [_job('running', id: 'j0')])),
        '/ai/studio/images/s1/content': _many(_jpeg),
        '/ai/studio/jobs/j0': _many(_job('running', id: 'j0')),
        ...extra,
      });
      // Sunucuda süren iş (uygulama yeniden açılmış): kutucuk ve izleme.
      expect(find.byKey(const ValueKey('ai-studio-pending-j0')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-studio-image-s1')));
      await _advance(tester, const Duration(milliseconds: 600));
      expect(find.byType(AiStudioViewer), findsOneWidget);
      return adapter;
    }

    testWidgets('Projeye ekle: proje + aşama gövdesi, "Projede" bilgisi', (tester) async {
      final adapter = await openViewer(tester, {
        '/dashboard/project-options': [
          (
            status: 200,
            body: {
              'projects': [
                {'id': 'p1', 'project_no': 'P-1', 'name': 'Villa', 'customer_name': '', 'currency': 'TRY', 'status': 'active'},
              ],
            },
          ),
        ],
        '/ai/studio/images/s1/add-to-project': [(status: 200, body: {'project_photo_id': 'pp1'})],
      });
      await tester.tap(find.byKey(const ValueKey('ai-studio-add-to-project')));
      await _advance(tester, const Duration(milliseconds: 600));
      // Tek açık proje: seçici atlanır, aşama sorulur (varsayılan Süreç).
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('ai-studio-stage-progress'))).selected, isTrue);
      await tester.tap(find.byKey(const ValueKey('ai-studio-stage-after')));
      await tester.pump();
      await tester.tap(find.widgetWithText(PrimaryButton, 'Projeye ekle'));
      await _advance(tester, const Duration(milliseconds: 600));
      final i = adapter.calls.indexOf('/ai/studio/images/s1/add-to-project');
      expect(adapter.requestBodies[i], {'project_id': 'p1', 'stage': 'after'});
      expect(find.text('Projede: Villa'), findsOneWidget);
    });

    testWidgets('Düzenle: kind=edit + source_studio_image_id, görsel yüklenmez', (tester) async {
      final adapter = await openViewer(tester, {
        '/ai/studio/jobs': [(status: 202, body: {'job': _job('queued', id: 'j2', kind: 'edit'), 'remaining': 95, 'limit': 100})],
        '/ai/studio/jobs/j2': _many(_job('running', id: 'j2', kind: 'edit')),
      });
      await tester.tap(find.byKey(const ValueKey('ai-studio-refine')));
      await _advance(tester, const Duration(milliseconds: 600));
      for (final example in kAiEditExamples) {
        expect(find.widgetWithText(ActionChip, example), findsOneWidget);
      }
      await tester.tap(find.widgetWithText(ActionChip, 'Tavanı koyu gri yap'));
      await tester.pump();
      await tester.tap(find.widgetWithText(PrimaryButton, 'Düzenle'));
      await _advance(tester, const Duration(milliseconds: 600));
      final sent = _form(adapter, '/ai/studio/jobs');
      expect(sent.fields, {'kind': 'edit', 'prompt': 'Tavanı koyu gri yap', 'source_studio_image_id': 's1'});
      expect(sent.files, isEmpty);
      expect(find.text(kAiStudioRefineStarted), findsWidgets);
      // Görüntüleyici açık kalır; asıl görsel yerinde.
      expect(find.byType(AiStudioViewer), findsOneWidget);
    });

    testWidgets('Sil: onaydan sonra DELETE, son görselse kapanır ve ızgaradan düşer', (tester) async {
      final adapter = await openViewer(tester, {
        '/ai/studio/images/s1': [(status: 204, body: null)],
      });
      await tester.tap(find.byKey(const ValueKey('ai-studio-delete')));
      await _settle(tester);
      expect(adapter.methods, isNot(contains('DELETE')));
      await tester.tap(find.widgetWithText(TextButton, 'Sil').last);
      await _advance(tester, const Duration(milliseconds: 600));
      expect(adapter.methods[adapter.calls.lastIndexOf('/ai/studio/images/s1')], 'DELETE');
      expect(find.byType(AiStudioViewer), findsNothing);
      expect(find.byKey(const ValueKey('ai-studio-image-s1')), findsNothing);
    });

    testWidgets('Paylaş / Kaydet: telefonun paylaşım menüsü (iOS\'ta "Görüntüyü Kaydet")', (tester) async {
      final sharer = FakeFileSharer();
      await _pumpStudio(tester, sharer: sharer, script: {
        '/ai/studio/images': _many(_page([_image('s1')])),
        '/ai/studio/images/s1/content': _many(_jpeg),
      });
      await tester.tap(find.byKey(const ValueKey('ai-studio-image-s1')));
      await _advance(tester, const Duration(milliseconds: 600));
      await tester.tap(find.text('Paylaş / Kaydet'));
      await _advance(tester, const Duration(milliseconds: 300));
      expect(sharer.files.single.mimeType, 'image/jpeg');
      expect(sharer.files.single.bytes, _jpeg);
    });
  });

  testWidgets('Firmadakiler: Sahip/Yönetici scope=firm ister; başka rolde seçici yok', (tester) async {
    final adapter = await _pumpStudio(tester, script: {'/ai/studio/images': _many(_page([]))});
    await tester.tap(find.text('Firmadakiler'));
    await _settle(tester);
    expect(adapter.requestQueries[adapter.calls.lastIndexOf('/ai/studio/images')]['scope'], 'firm');

    await _pumpStudio(tester, user: _user(roleCode: 'field'), script: {'/ai/studio/images': _many(_page([]))});
    expect(find.byKey(const ValueKey('ai-studio-scope')), findsNothing);
  });

  testWidgets('kaydırınca next_before ile devamı', (tester) async {
    final adapter = await _pumpStudio(tester, size: const Size(360, 640), script: {
      '/ai/studio/images': [
        (status: 200, body: _page([for (var i = 0; i < 30; i++) _image('a$i')], next: 'c1')),
        (status: 200, body: _page([_image('b0')])),
      ],
      for (var i = 0; i < 30; i++) '/ai/studio/images/a$i/content': _many(_jpeg),
      '/ai/studio/images/b0/content': _many(_jpeg),
    });
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await _settle(tester);
    final second = adapter.calls.lastIndexOf('/ai/studio/images');
    expect(adapter.requestQueries[second]['before'], 'c1');
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await _settle(tester);
    expect(find.byKey(const ValueKey('ai-studio-image-b0')), findsOneWidget);
  });

  testWidgets('320 pt + büyük yazı: ekran, sayfalar ve görüntüleyici taşmaz', (tester) async {
    await _pumpStudio(tester, size: const Size(320, 640), textScale: 1.6, script: {
      '/ai/studio/images': _many(_page([_image('s1')], pending: [_job('running', id: 'j0', kind: 'before_after')])),
      '/ai/studio/images/s1/content': _many(_jpeg),
      '/ai/studio/jobs/j0': _many(_job('running', id: 'j0')),
    });
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('ai-studio-generate')));
    await _advance(tester, const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.text('Yeni görsel oluştur').last)).pop();
    await _advance(tester, const Duration(milliseconds: 600));

    await tester.tap(find.byKey(const ValueKey('ai-studio-upload')));
    await _advance(tester, const Duration(milliseconds: 600));
    await tester.tap(find.text('Galeriden seç'));
    await _advance(tester, const Duration(milliseconds: 600));
    await tester.tap(find.byKey(const ValueKey('ai-studio-mode-custom')));
    await _advance(tester, const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.text('Fotoğrafı düzenle'))).pop();
    await _advance(tester, const Duration(milliseconds: 600));

    await tester.dragUntilVisible(
      find.byKey(const ValueKey('ai-studio-image-s1')),
      find.byType(CustomScrollView),
      const Offset(0, -200),
    );
    await tester.tap(find.byKey(const ValueKey('ai-studio-image-s1')));
    await _advance(tester, const Duration(milliseconds: 600));
    expect(find.byType(AiStudioViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('Alanı işaretle (maske)', () {
    test('maske kaynakla aynı boyutta; boyanan yer saydam, gerisi opak', () async {
      final mask = await aiMaskFromStrokes(width: 64, height: 48, strokes: const [
        AiMaskStroke(points: [Offset(10, 24), Offset(54, 24)], width: 6),
      ]);
      final img = await _decode(mask!.png);
      expect((img.width, img.height), (64, 48));
      expect(img.alpha(32, 24), 0);
      expect(img.alpha(10, 24), 0);
      expect(img.alpha(32, 5), 255);
      expect(img.alpha(2, 2), 255);
      // Tek dokunuş da bir nokta işaretler.
      final dot = await _decode((await aiMaskFromStrokes(width: 20, height: 20, strokes: const [
        AiMaskStroke(points: [Offset(10, 10)], width: 6),
      ]))!.png);
      expect(dot.alpha(10, 10), 0);
      expect(dot.alpha(1, 1), 255);
    });

    test('hiçbir yer boyanmadıysa maske yok', () async {
      expect(await aiMaskFromStrokes(width: 64, height: 48, strokes: const []), isNull);
      expect(
        await aiMaskFromStrokes(width: 64, height: 48, strokes: const [AiMaskStroke(points: [], width: 6)]),
        isNull,
      );
    });

    test('multipart: maske "mask" parçası olarak gider (Stüdyo ve proje)', () async {
      final png = Uint8List.fromList(const [1, 2, 3]);
      final adapter = FakeHttpClientAdapter(script: {
        '/ai/studio/jobs': _many({'job': _job('queued', kind: 'edit')}, status: 202),
        '/projects/p1/ai-image-jobs': _many({
          'job': {'id': 'j1', 'project_id': 'p1', 'kind': 'edit', 'status': 'queued'},
        }, status: 202),
      });
      final client = await buildFakeApiClient(adapter);
      await AiStudioRepository(client).createJob(kind: 'edit', prompt: 'Spot ışık ekle', sourceStudioImageId: 's1', mask: png);
      var form = adapter.requestBodies[0] as FormData;
      expect({for (final f in form.fields) f.key: f.value}, {
        'kind': 'edit',
        'prompt': 'Spot ışık ekle',
        'source_studio_image_id': 's1',
      });
      expect(form.files.single.key, 'mask');
      expect(form.files.single.value.contentType.toString(), 'image/png');

      final projects = AiImagesRepository(client);
      await projects.createJob('p1', kind: 'edit', prompt: 'Spot ışık ekle', sourcePhotoId: 'ph1', mask: png);
      form = adapter.requestBodies[1] as FormData;
      expect({for (final f in form.fields) f.key: f.value}, {
        'kind': 'edit',
        'prompt': 'Spot ışık ekle',
        'source_photo_id': 'ph1',
      });
      expect(form.files.single.key, 'mask');
      // Maskesiz proje isteği 1.5.22'deki gibi JSON.
      await projects.createJob('p1', kind: 'edit', prompt: 'Spot ışık ekle', sourcePhotoId: 'ph1');
      expect(adapter.requestBodies[2], {'kind': 'edit', 'prompt': 'Spot ışık ekle', 'source_photo_id': 'ph1'});
    });

    testWidgets('kalemle boyanınca Tamam: maske kaynak piksel boyutunda, boyanan yer saydam; Geri al/Temizle',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final source = (await tester.runAsync(() => _png(80, 60)))!;
      AiMaskEditResult? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async => result = await showAiMaskEditor(context, sourceBytes: source),
                child: const Text('Aç'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Aç'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      final canvas = find.byKey(const ValueKey('ai-mask-canvas'));
      expect(canvas, findsOneWidget);

      // Bir çizgi çizip geri al, temizle: hiçbir şey kalmaz.
      final center = tester.getCenter(canvas);
      await tester.dragFrom(center - const Offset(100, 0), const Offset(200, 0));
      await tester.pump();
      await tester.tap(find.byTooltip('Geri al'));
      await tester.pump();
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('ai-mask-undo'))).onPressed, isNull);

      // Ortadan yatay bir çizgi.
      await tester.dragFrom(center - const Offset(100, 0), const Offset(200, 0));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ai-mask-done')));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await _settle(tester);
      final mask = result!.mask!;
      expect((mask.width, mask.height), (80, 60));
      final img = (await tester.runAsync(() => _decode(mask.png)))!;
      expect((img.width, img.height), (80, 60));
      expect(img.alpha(40, 30), 0);
      expect(img.alpha(40, 3), 255);
    });

    testWidgets('boyamadan Tamam: maske yok (bütün görsel düzenlenir)', (tester) async {
      final source = (await tester.runAsync(() => _png(40, 30)))!;
      AiMaskEditResult? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async => result = await showAiMaskEditor(context, sourceBytes: source),
            child: const Text('Aç'),
          ),
        ),
      ));
      await tester.tap(find.text('Aç'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('ai-mask-done')));
      await _settle(tester);
      expect(result, isNotNull);
      expect(result!.mask, isNull);
    });
  });
}
