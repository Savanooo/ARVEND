@Tags(['golden'])
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/presentation/project_photo_gallery.dart';

import '../products/products_fakes.dart' show loadAppFonts, productsTestTheme;

/// Proje fotoğraf galerisi, küçük telefon dikey (360x800) ve yatay
/// (800x360): koyu zemin, üstte geri oku + sayaç + paylaş/sil, altta aşama,
/// açıklama, tarih ve "Sil". Üretmek:
///   flutter test --tags golden --update-goldens test/features/projects/project_photo_gallery_golden_test.dart

/// Basit bir "şantiye" resmi (gök, yapı, zemin) -- gerçek PNG baytı, galeri
/// gerçek bir görüntü çözsün.
Future<Uint8List> _scene(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final w = width.toDouble();
  final h = height.toDouble();
  canvas.drawRect(Rect.fromLTWH(0, 0, w, h * 0.6), Paint()..color = const Color(0xFF8DB3CC));
  canvas.drawRect(Rect.fromLTWH(0, h * 0.6, w, h * 0.4), Paint()..color = const Color(0xFF9A8269));
  canvas.drawRect(Rect.fromLTWH(w * 0.18, h * 0.22, w * 0.5, h * 0.42), Paint()..color = const Color(0xFFC9C3B8));
  for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 2; j++) {
      canvas.drawRect(
        Rect.fromLTWH(w * (0.24 + i * 0.14), h * (0.28 + j * 0.16), w * 0.08, h * 0.09),
        Paint()..color = const Color(0xFF4F6272),
      );
    }
  }
  canvas.drawRect(Rect.fromLTWH(w * 0.74, h * 0.1, w * 0.03, h * 0.55), Paint()..color = const Color(0xFFE0A030));
  canvas.drawRect(Rect.fromLTWH(w * 0.55, h * 0.1, w * 0.35, h * 0.03), Paint()..color = const Color(0xFFE0A030));
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
      'id': 'ph0',
      'original_name': 'IMG_0001.jpg',
      'mime_type': 'image/jpeg',
      'stage': 'before',
      'description': '',
      'created_at': '2026-10-01T09:30:00',
    }),
    ProjectPhoto.fromJson(const {
      'id': 'ph1',
      'original_name': 'IMG_0002.jpg',
      'mime_type': 'image/jpeg',
      'stage': 'progress',
      'description': 'B blok 2. kat kolon kalıpları söküldü, döşeme donatısı başladı.',
      'created_at': '2026-10-12T14:40:00',
    }),
    ProjectPhoto.fromJson(const {
      'id': 'ph2',
      'original_name': 'IMG_0003.jpg',
      'mime_type': 'image/jpeg',
      'stage': 'after',
      'description': '',
      'created_at': '2026-10-20T16:05:00',
    }),
  ];

  for (final (name, size) in [
    ('project_photo_gallery_360x800', const Size(360, 800)),
    ('project_photo_gallery_landscape_800x360', const Size(800, 360)),
  ]) {
    testWidgets(name, (tester) async {
      tester.view.devicePixelRatio = 2.0;
      tester.view.physicalSize = size * 2.0;
      addTearDown(tester.view.reset);
      final scene = (await tester.runAsync(() => _scene(1200, 900)))!;

      await tester.pumpWidget(ProviderScope(
        overrides: [projectPhotoBytesProvider.overrideWith((ref, key) async => scene)],
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
      // Görüntü çözme gerçek zamanda biter.
      await tester.runAsync(() async {
        for (final element in find.byType(Image).evaluate()) {
          await precacheImage((element.widget as Image).image, element);
        }
      });
      await tester.pumpAndSettle();

      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    });
  }
}
