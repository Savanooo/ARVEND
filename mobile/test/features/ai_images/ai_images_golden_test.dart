@Tags(['golden'])
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/features/ai_images/data/ai_images_providers.dart';
import 'package:arvend/features/ai_images/domain/ai_image.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/presentation/project_photo_gallery.dart';

import '../../test_utils/fake_api_client.dart';
import '../products/products_fakes.dart' show loadAppFonts, productsTestTheme;

/// Yapay zekâ görselleri, küçük telefon (360x800): galeride üretilmiş görselin
/// rozeti + "Yapay zekâ ile üretildi · kaynak: `tarih`" ve üst çubukta
/// "Yapay zekâ" düğmesi; o düğmenin açtığı sayfa (örnekler 360 dp'de kaymadan
/// sarılıyor mu, kalan hak). Üretmek:
///   flutter test --tags golden --update-goldens test/features/ai_images/ai_images_golden_test.dart

Future<Uint8List> _room(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final w = width.toDouble();
  final h = height.toDouble();
  canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = const Color(0xFFEDE8DF));
  canvas.drawRect(Rect.fromLTWH(0, 0, w, h * 0.12), Paint()..color = const Color(0xFFFAFAFA));
  for (var i = 0; i < 4; i++) {
    canvas.drawCircle(Offset(w * (0.2 + i * 0.2), h * 0.06), w * 0.015, Paint()..color = const Color(0xFFFFE9A8));
  }
  canvas.drawRect(Rect.fromLTWH(0, h * 0.78, w, h * 0.22), Paint()..color = const Color(0xFFB08A63));
  canvas.drawRect(Rect.fromLTWH(w * 0.6, h * 0.3, w * 0.22, h * 0.35), Paint()..color = const Color(0xFF9CC3DA));
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await loadAppFonts();
  });

  // Zamanlar saat dilimsiz: golden, makinenin saat diliminden bağımsız.
  final photos = [
    ProjectPhoto.fromJson(const {
      'id': 'ph1',
      'original_name': 'salon.jpg',
      'mime_type': 'image/jpeg',
      'stage': 'before',
      'description': 'Salon, sıva bitti',
      'created_at': '2026-10-01T09:30:00',
    }),
    ProjectPhoto.fromJson(const {
      'id': 'ai1',
      'original_name': 'yapay-zeka-bitmis-hali.jpg',
      'mime_type': 'image/jpeg',
      'stage': 'after',
      'description': 'Bitmiş hali (yapay zekâ görseli): Alçıpan asma tavan, spot ışıklı, beyaz boya',
      'created_at': '2026-10-29T11:05:00',
      'ai_generated': true,
      'ai': {
        'kind': 'before_after',
        'prompt': 'Alçıpan asma tavan, spot ışıklı, beyaz boya',
        'source_photo_id': 'ph1',
        'source_date': '2026-10-01T09:30:00',
      },
    }),
  ];

  Future<void> pumpGallery(WidgetTester tester) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(360, 800) * 2.0;
    addTearDown(tester.view.reset);
    final room = (await tester.runAsync(() => _room(1200, 900)))!;
    final client = await buildFakeApiClient(FakeHttpClientAdapter(script: {
      '/projects/p1/ai-image-jobs': [(status: 200, body: {'jobs': <dynamic>[]})],
    }));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        projectPhotoBytesProvider.overrideWith((ref, key) async => room),
        aiImageStatusProvider.overrideWith((ref) async => const AiImageStatus(
              enabled: true,
              canUse: true,
              quota: AiImageQuota(
                monthlyLimit: 100,
                usedThisMonth: 3,
                remaining: 97,
                userHourlyLimit: 10,
                resetsAt: '2026-11-01T00:00:00',
              ),
            )),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: productsTestTheme(),
        locale: const Locale('tr', 'TR'),
        supportedLocales: const [Locale('tr', 'TR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showProjectPhotoGallery(
                  context,
                  projectId: 'p1',
                  photos: photos,
                  initialIndex: 1,
                  canDelete: true,
                  canUseAi: true,
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
    await tester.runAsync(() async {
      for (final element in find.byType(Image).evaluate()) {
        await precacheImage((element.widget as Image).image, element);
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('ai_gallery_caption_360x800', (tester) async {
    await pumpGallery(tester);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/ai_gallery_caption_360x800.png'));
  });

  testWidgets('ai_photo_sheet_360x800', (tester) async {
    await pumpGallery(tester);
    await tester.tap(find.byTooltip('Yapay zekâ'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      for (final element in find.byType(Image).evaluate()) {
        await precacheImage((element.widget as Image).image, element);
      }
    });
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/ai_photo_sheet_360x800.png'));
  });
}
