import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/files/file_share.dart';
import 'package:arvend/core/utils/formatters.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/presentation/project_photo_gallery.dart';

import '../../test_utils/fake_api_client.dart';
import '../../test_utils/fake_file_sharer.dart';
import 'project_documents_test.dart' show photoJson, pumpProject;

/// Proje fotoğraf galerisi ("resimler sıra sıra kaymıyor, galeri değil"):
/// dokunulan fotoğrafta açılır, ızgaranın sırasıyla kaydırılır, yakınken
/// kaydırma sayfa değiştirmez, paylaş/sil görünen fotoğrafa uygulanır.

ProjectPhoto _photo(String id, {String stage = 'progress', String description = ''}) =>
    ProjectPhoto.fromJson(photoJson(id, stage: stage, description: description));

/// Galeriyi bir "Aç" düğmesinin arkasından açar: kapanınca düğme görünür.
Future<FakeHttpClientAdapter> _pumpGallery(
  WidgetTester tester, {
  required List<ProjectPhoto> photos,
  int initialIndex = 0,
  bool canDelete = true,
  Size size = const Size(400, 800),
  Map<String, List<ScriptedResponse>> extra = const {},
  List<Override> overrides = const [],
  List<ProjectPhoto>? deleted,
}) async {
  final adapter = FakeHttpClientAdapter(script: {
    for (final p in photos)
      '/projects/p1/photos/${p.id}/content': [
        for (var i = 0; i < 4; i++) (status: 200, body: <int>[0xFF, 0xD8, 0xFF, 0xE0]),
      ],
    ...extra,
  });
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(client),
      projectPhotoCacheProvider.overrideWithValue(ProjectPhotoCache(directory: () async => null)),
      ...overrides,
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showProjectPhotoGallery(
                context,
                projectId: 'p1',
                photos: photos,
                initialIndex: initialIndex,
                canDelete: canDelete,
                onDeleted: deleted?.add,
              ),
              child: const Text('Aç'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Aç'));
  await tester.pumpAndSettle();
  return adapter;
}

final _pages = find.byKey(const ValueKey('photo-gallery-pages'));

String _counter(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('photo-gallery-counter'))).data!;

Future<void> _swipe(WidgetTester tester, double dx) async {
  await tester.fling(_pages, Offset(dx, 0), 1500);
  await tester.pumpAndSettle();
}

Future<void> _doubleTap(WidgetTester tester) async {
  final center = tester.getCenter(_pages);
  await tester.tapAt(center);
  await tester.pump(const Duration(milliseconds: 60));
  await tester.tapAt(center);
  await tester.pumpAndSettle();
}

/// Görünen sayfanın yakınlaştırma ölçeği.
double _scale(WidgetTester tester) {
  final viewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer).hitTestable());
  return viewer.transformationController!.value.getMaxScaleOnAxis();
}

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  final three = [
    _photo('ph0', stage: 'before', description: 'Kırım öncesi banyo'),
    _photo('ph1', stage: 'progress', description: 'Tesisat döşendi'),
    _photo('ph2', stage: 'after', description: 'Seramik bitti'),
  ];

  testWidgets('dokunulan fotoğrafta açılır: sayaç, aşama, açıklama ve tarih', (tester) async {
    await _pumpGallery(tester, photos: three, initialIndex: 1);

    expect(_counter(tester), '2 / 3');
    expect(find.text('Tesisat döşendi'), findsOneWidget);
    expect(find.text('İlerleme'), findsOneWidget);
    expect(find.text(Formatters.dateTime(three[1].createdAt)), findsOneWidget);
    // Geri oku (tam ekran rota, alt sayfa değil).
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('sağa/sola kaydırınca bütün fotoğraflar sırayla gezilir; uçlarda durur', (tester) async {
    await _pumpGallery(tester, photos: three, initialIndex: 1);

    await _swipe(tester, -400);
    expect(_counter(tester), '3 / 3');
    expect(find.text('Seramik bitti'), findsOneWidget);
    expect(find.text('İş Sonrası'), findsOneWidget);

    await _swipe(tester, -400);
    expect(_counter(tester), '3 / 3', reason: 'son fotoğraftan sonrası yok');

    await _swipe(tester, 400);
    await _swipe(tester, 400);
    expect(_counter(tester), '1 / 3');
    expect(find.text('Kırım öncesi banyo'), findsOneWidget);
  });

  testWidgets('çift dokunuş yakınlaştırır: yakınken kaydırma fotoğrafı gezdirir, sayfa değişmez', (tester) async {
    await _pumpGallery(tester, photos: three, initialIndex: 1);

    await _doubleTap(tester);
    expect(_scale(tester), greaterThan(2));

    final viewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer).hitTestable());
    final before = viewer.transformationController!.value.getTranslation();
    await tester.drag(_pages, const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(_counter(tester), '2 / 3', reason: 'yakınken sayfa kaymaz');
    expect(viewer.transformationController!.value.getTranslation().x, isNot(before.x), reason: 'fotoğraf gezdirildi');

    // Çift dokunuş 1x'e döndürür; kaydırma yeniden sayfa değiştirir.
    await _doubleTap(tester);
    expect(_scale(tester), closeTo(1, 0.01));
    await _swipe(tester, -400);
    expect(_counter(tester), '3 / 3');
  });

  testWidgets('iki parmakla açınca yakınlaşır, sayfa kaymaz', (tester) async {
    await _pumpGallery(tester, photos: three, initialIndex: 1);

    final center = tester.getCenter(_pages);
    final a = await tester.startGesture(center - const Offset(30, 0), pointer: 1);
    await tester.pump();
    final b = await tester.startGesture(center + const Offset(30, 0), pointer: 2);
    await tester.pump();
    // Bir parmak sabit, öteki yatayda açılır: tek başına yatay kaydırmaya
    // benzer, sayfa kaydırma bunu kapıyordu.
    for (var i = 0; i < 8; i++) {
      await b.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();

    expect(_counter(tester), '2 / 3');
    expect(_scale(tester), greaterThan(1.5));
  });

  testWidgets('Sil görünen fotoğrafı siler, sıradaki gelir; sondaysa öncekine; son silinince kapanır', (tester) async {
    final deleted = <ProjectPhoto>[];
    final adapter = await _pumpGallery(
      tester,
      photos: three,
      initialIndex: 1,
      deleted: deleted,
      extra: {
        for (final p in three) '/projects/p1/photos/${p.id}': [(status: 200, body: {'ok': true})],
      },
    );

    Future<void> delete() async {
      await tester.tap(find.widgetWithText(TextButton, 'Sil'));
      await tester.pumpAndSettle();
      expect(find.text('Bu fotoğraf silinsin mi?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Sil').last);
      await tester.pumpAndSettle();
    }

    await delete();
    expect(adapter.calls.where((c) => c == '/projects/p1/photos/ph1'), hasLength(1));
    expect(_counter(tester), '2 / 2');
    expect(find.text('Seramik bitti'), findsOneWidget, reason: 'sıradaki fotoğraf geldi');

    await delete();
    expect(adapter.calls, contains('/projects/p1/photos/ph2'));
    expect(_counter(tester), '1 / 1');
    expect(find.text('Kırım öncesi banyo'), findsOneWidget, reason: 'sondaki silinince önceki');

    await delete();
    expect(adapter.calls, contains('/projects/p1/photos/ph0'));
    expect(find.byKey(const ValueKey('photo-gallery-counter')), findsNothing, reason: 'galeri kapandı');
    expect(find.text('Aç'), findsOneWidget);
    expect(deleted.map((p) => p.id), ['ph1', 'ph2', 'ph0']);
  });

  testWidgets('silinemeyen fotoğraf yerinde kalır, sunucunun mesajı görünür', (tester) async {
    await _pumpGallery(tester, photos: three, initialIndex: 0, extra: {
      '/projects/p1/photos/ph0': [(status: 403, body: {'error': 'bu işlem için yetkiniz yok'})],
    });

    await tester.tap(find.byTooltip('Fotoğrafı sil'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Sil').last);
    await tester.pumpAndSettle();

    // Alttaki ekranın iskeleti de aynı bildirimi taşır (rota opak değil).
    expect(find.text('bu işlem için yetkiniz yok'), findsWidgets);
    expect(_counter(tester), '1 / 3');
    // Sayfa kaydırma yeniden açık.
    await _swipe(tester, -400);
    expect(_counter(tester), '2 / 3');
  });

  testWidgets('silme yetkisi yoksa Sil yok; paylaş görünen fotoğrafı açıklamasıyla gönderir', (tester) async {
    final sharer = FakeFileSharer();
    await _pumpGallery(
      tester,
      photos: three,
      canDelete: false,
      overrides: [fileSharerProvider.overrideWithValue(sharer)],
    );
    expect(find.byTooltip('Fotoğrafı sil'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Sil'), findsNothing);

    await _swipe(tester, -400);
    await tester.tap(find.byTooltip('Fotoğrafı paylaş'));
    await tester.pumpAndSettle();

    final shared = sharer.files.single;
    expect(shared.filename, 'ph1.jpg');
    expect(shared.text, 'Tesisat döşendi');
  });

  testWidgets('aşağı kaydırınca kapanır; az kaydırınca yerine döner', (tester) async {
    await _pumpGallery(tester, photos: three, initialIndex: 1);

    Future<void> dragDown(double total) async {
      final g = await tester.startGesture(tester.getCenter(_pages));
      const step = 20.0;
      for (var moved = 0.0; moved < total; moved += step) {
        await g.moveBy(const Offset(0, step));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await g.up();
      await tester.pumpAndSettle();
    }

    await dragDown(80);
    expect(_counter(tester), '2 / 3', reason: 'kısa sürükleme kapatmaz');
    final transform = tester.widget<Transform>(
      find.ancestor(of: _pages, matching: find.byType(Transform)).first,
    );
    expect(transform.transform.getTranslation().y, 0, reason: 'yerine döndü');

    await dragDown(300);
    expect(find.byKey(const ValueKey('photo-gallery-counter')), findsNothing);
    expect(find.text('Aç'), findsOneWidget);
  });

  testWidgets('geri tuşu (üst çubuk) kapatır', (tester) async {
    await _pumpGallery(tester, photos: three);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Aç'), findsOneWidget);
  });

  testWidgets('tek dokunuş üst çubuğu ve açıklamayı gizler, ikincisi geri getirir', (tester) async {
    await _pumpGallery(tester, photos: three);

    // Tek dokunuş, çift dokunuş süresi dolunca sayılır.
    await tester.tapAt(tester.getCenter(_pages));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Fotoğrafı paylaş').hitTestable(), findsNothing);

    await tester.tapAt(tester.getCenter(_pages));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Fotoğrafı paylaş').hitTestable(), findsOneWidget);
  });

  testWidgets('komşu fotoğraflar önceden yüklenir, uzaktakiler yüklenmez', (tester) async {
    final six = [for (var i = 0; i < 6; i++) _photo('ph$i')];
    final adapter = await _pumpGallery(tester, photos: six, initialIndex: 2);

    final fetched = adapter.calls.where((c) => c.endsWith('/content')).toSet();
    expect(fetched, {
      '/projects/p1/photos/ph1/content',
      '/projects/p1/photos/ph2/content',
      '/projects/p1/photos/ph3/content',
    });
  });

  for (final (name, size) in [('küçük telefon 320x568', const Size(320, 568)), ('yatay 800x360', const Size(800, 360))]) {
    testWidgets('$name: taşma yok, sayaç ve düğmeler yerinde', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pumpGallery(tester, size: size, photos: [
        _photo('ph0', stage: 'before', description: 'Bodrum kat perde duvar kalıbı söküldü, ' * 6),
        _photo('ph1'),
      ]);

      expect(tester.takeException(), isNull);
      expect(_counter(tester), '1 / 2');
      expect(find.byTooltip('Fotoğrafı paylaş'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Sil').hitTestable(), findsOneWidget);
      await _swipe(tester, -size.width);
      expect(_counter(tester), '2 / 2');
    });
  }

  testWidgets('Dökümanlar: ızgaradaki sırayla (önce -> süreç -> sonra) açılır ve kayar', (tester) async {
    // Backend aşamayı alfabetik sıralar ("after" önce); ızgara iş sırasına dizer.
    final photos = [
      photoJson('ph-after', stage: 'after', description: 'Teslim'),
      photoJson('ph-before', stage: 'before', description: 'Başlangıç'),
      photoJson('ph-progress', stage: 'progress', description: 'Süreç'),
    ];
    await pumpProject(tester, group: 'dokumanlar', photos: photos, extra: {
      for (final p in photos)
        '/projects/p1/photos/${p['id']}/content': [
          for (var i = 0; i < 4; i++) (status: 200, body: <int>[0xFF, 0xD8, 0xFF, 0xE0]),
        ],
    });

    await tester.tap(find.byKey(const ValueKey('proje-foto-ph-progress')));
    await tester.pumpAndSettle();
    expect(_counter(tester), '2 / 3');
    expect(find.text('Süreç'), findsOneWidget);

    await _swipe(tester, -400);
    expect(find.text('Teslim'), findsOneWidget);
    await _swipe(tester, 400);
    await _swipe(tester, 400);
    expect(find.text('Başlangıç'), findsOneWidget);
    expect(_counter(tester), '1 / 3');
  });
}
