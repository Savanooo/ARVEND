@Tags(['golden'])
library;

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/chat/data/chat_providers.dart';
import 'package:arvend/features/chat/domain/chat_message.dart';
import 'package:arvend/features/chat/presentation/chat_screen.dart';

import '../../test_utils/fake_api_client.dart';

/// Firma Grubu ekran görüntüleri: 360x800 ve 320 pt + büyük yazı. Üretmek:
///   flutter test --tags golden --update-goldens test/features/chat/chat_golden_test.dart
/// Tarihler 2025'te sabit (gün ayracı "3 Mart 2025" -- her gün değişmez);
/// gönderilemeyen mesajın ayracı "Bugün".

Future<void> _loadAppFonts() async {
  final manifest = json.decode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

ThemeData _goldenTheme() {
  final theme = AppTheme.light();
  return theme.copyWith(
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Inter'),
    ),
  );
}

class _Auth extends AuthController {
  @override
  Future<User?> build() async => const User(
        id: 'u-ahmet',
        organizationId: 'org-1',
        username: 'ahmet',
        fullName: 'Ahmet Saha',
        role: UserRole.kullanici,
        isActive: true,
        mustChangePassword: false,
        onboardingCompleted: true,
        onboardingStep: 'completed',
        organizationRoleCode: 'field',
        permissions: {kPermOrganizationChatUse},
      );
}

class _NoCache extends ChatCache {
  _NoCache() : super(directory: () async => null);
}

Map<String, dynamic> _m(int seq, String at, {String author = 'u-mehmet', String name = 'Mehmet Usta', String text = '', bool own = false, bool deleted = false, bool photo = false}) => {
      'id': 'm$seq',
      'seq': seq,
      'author_id': own ? 'u-ahmet' : author,
      'author_name': own ? 'Ahmet Saha' : name,
      'text': text,
      'photo': photo ? {'mime_type': 'image/png', 'size_bytes': 1000} : null,
      'created_at': at,
      'deleted': deleted,
      'is_own': own,
      'can_delete': own,
    };

final _page = {
  'messages': [
    _m(7, '2025-03-04T07:12:00Z', own: true, text: 'Tamam, 8\'de oradayım.'),
    _m(6, '2025-03-04T07:05:00Z', author: 'u-ayse', name: 'Ayşe Sahip', text: 'Beton pompası 8:30\'da geliyor, herkes şantiyede olsun.'),
    _m(5, '2025-03-04T06:58:00Z', photo: true, text: 'Kolon donatısı bitti'),
    _m(4, '2025-03-04T06:57:00Z', text: 'Günaydın'),
    _m(3, '2025-03-03T15:40:00Z', deleted: true),
    _m(2, '2025-03-03T15:31:00Z', own: true, text: 'Malzeme listesi ekte, eksik varsa yazın.'),
    _m(1, '2025-03-03T15:30:00Z', author: 'u-ayse', name: 'Ayşe Sahip', text: 'Yarınki döküm için malzemeler tamam mı?'),
  ],
  'has_more': false,
  'updated': <dynamic>[],
  'last_read_seq': 3,
  'muted': false,
  'can_moderate': false,
  'server_time': '2025-03-04T07:13:00Z',
};

/// Küçük resim için gerçek bir PNG (gökyüzü/beton tonları) -- 1x1 piksel
/// yerine görüntüde fotoğraf gibi dursun.
Future<Uint8List> _photo() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 160, 120), Paint()..color = const Color(0xFF93C5FD));
  canvas.drawRect(const Rect.fromLTWH(0, 70, 160, 50), Paint()..color = const Color(0xFF9CA3AF));
  for (var x = 20.0; x < 160; x += 30) {
    canvas.drawRect(Rect.fromLTWH(x, 30, 8, 60), Paint()..color = const Color(0xFF6B7280));
  }
  final image = await recorder.endRecording().toImage(160, 120);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  late Uint8List photo;

  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await _loadAppFonts();
  });

  Future<void> shoot(WidgetTester tester, String name, Size size, {double textScale = 1.0}) async {
    photo = (await tester.runAsync(_photo))!;
    final adapter = FakeHttpClientAdapter(script: {
      '/organization/chat/messages': [(status: 200, body: _page)],
      '/organization/chat/read': [(status: 200, body: {'unread_count': 0, 'muted': false, 'last_read_seq': 7})],
    });
    final container = ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(await buildFakeApiClient(adapter)),
      authControllerProvider.overrideWith(_Auth.new),
      chatCacheProvider.overrideWithValue(_NoCache()),
      chatPhotoBytesProvider.overrideWith((ref, id) async => photo),
    ]);
    addTearDown(container.dispose);
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = size * 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _goldenTheme(),
        locale: const Locale('tr', 'TR'),
        supportedLocales: const [Locale('tr', 'TR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const ChatScreen(),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();
    // Gönderilemeyen bir mesaj (kuyruk yok: "Tekrar dene").
    final notifier = container.read(chatControllerProvider.notifier);
    container.read(chatControllerProvider.notifier).state = notifier.state.copyWith(pending: [
      PendingChatMessage(
        clientId: 'c1',
        text: 'Pompa geç kalırsa haber verin',
        createdAt: DateTime.now().toUtc(),
        status: ChatSendStatus.failed,
        error: 'Bağlantı yok',
      ),
    ]);
    await tester.pump();
    // Küçük resmin çözülmesi gerçek zamanda olur.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
  }

  testWidgets('sohbet 360x800', (tester) => shoot(tester, 'chat_360x800', const Size(360, 800)));
  testWidgets('sohbet 320 pt büyük yazı', (tester) => shoot(tester, 'chat_320_large_text', const Size(320, 640), textScale: 1.6));
}
