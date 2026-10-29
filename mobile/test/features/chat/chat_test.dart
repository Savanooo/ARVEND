import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/app/app_router.dart';
import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/config/app_config.dart';
import 'package:arvend/core/files/device_picker.dart' show PickedDeviceFile;
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/chat/data/chat_providers.dart';
import 'package:arvend/features/chat/domain/chat_format.dart';
import 'package:arvend/features/chat/domain/chat_message.dart';
import 'package:arvend/features/chat/presentation/chat_entry.dart';
import 'package:arvend/features/chat/presentation/chat_screen.dart';
import 'package:arvend/features/profile/presentation/other_menu_screen.dart';

import '../../test_utils/fake_api_client.dart';

/// Firma Grubu (backend migration 0077): sohbet ekranı, gönderme/tekrar
/// deneme, yoklama, çevrimdışı önbellek, silme, sessize alma, girişler.

const _list = '/organization/chat/messages';
const _read = '/organization/chat/read';

/// Bellek içi önbellek (dosya sistemi testte yavaş/asenkron): yazılan
/// görünüm JSON'a gidip geri gelir -- serileştirme de sınanır.
class _MemoryChatCache extends ChatCache {
  _MemoryChatCache() : super(directory: () async => null);
  final snapshots = <String, ChatSnapshot>{};
  final photos = <String, Uint8List>{};

  @override
  Future<ChatSnapshot?> read(String userId) async => snapshots[userId];
  @override
  Future<void> write(String userId, ChatSnapshot snapshot) async =>
      snapshots[userId] = ChatSnapshot.fromJson(jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, dynamic>);
  @override
  Future<Uint8List?> readPhoto(String messageId) async => photos[messageId];
  @override
  Future<void> writePhoto(String messageId, Uint8List bytes) async => photos[messageId] = bytes;
  @override
  Future<void> removePhoto(String messageId) async => photos.remove(messageId);
}

/// Sahte adaptörün önüne "bağlantı yok" anahtarı: açıkken her istek
/// SocketException ile düşer (ApiClient bunu ağ hatasına çevirir).
class _SwitchableAdapter implements HttpClientAdapter {
  _SwitchableAdapter(this.inner);
  final FakeHttpClientAdapter inner;
  bool offline = false;
  final offlineCalls = <String>[];
  final offlineBodies = <Object?>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    if (offline) {
      offlineCalls.add(options.path);
      offlineBodies.add(options.data);
      throw const SocketException('bağlantı yok');
    }
    return inner.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

class _Auth extends AuthController {
  _Auth(this._user);
  final User? _user;
  @override
  Future<User?> build() async => _user;
}

class _FakePicker implements ChatPhotoPicker {
  PickedDeviceFile? next;
  @override
  Future<PickedDeviceFile?> pick(ImageSource source) async => next;
}

User _user({
  String id = 'u-ahmet',
  Set<String> permissions = const {kPermOrganizationChatUse, 'notifications.read'},
  String? supplierId,
  UserRole role = UserRole.kullanici,
}) =>
    User(
      id: id,
      organizationId: 'org-1',
      username: 'ahmet',
      fullName: 'Ahmet Saha',
      role: role,
      isActive: true,
      mustChangePassword: false,
      onboardingCompleted: true,
      onboardingStep: 'completed',
      organizationName: 'Arvend Yapı',
      organizationRoleCode: supplierId == null ? 'field' : 'subcontractor',
      permissions: permissions,
      supplierId: supplierId,
    );

Map<String, dynamic> _msg(
  int seq, {
  String? id,
  String author = 'u-mehmet',
  String name = 'Mehmet Usta',
  String text = '',
  bool own = false,
  bool deleted = false,
  bool? canDelete,
  bool photo = false,
  DateTime? at,
}) =>
    {
      'id': id ?? 'm$seq',
      'seq': seq,
      'author_id': own ? 'u-ahmet' : author,
      'author_name': own ? 'Ahmet Saha' : name,
      'text': deleted ? '' : text,
      'photo': photo && !deleted ? {'mime_type': 'image/png', 'size_bytes': _png.length} : null,
      'created_at': (at ?? clock.now()).toUtc().toIso8601String(),
      'deleted': deleted,
      'is_own': own,
      'can_delete': canDelete ?? (own && !deleted),
    };

/// [messages] yeniden eskiye verilir (sunucu sözleşmesi).
Map<String, dynamic> _page(
  List<Map<String, dynamic>> messages, {
  bool hasMore = false,
  List<Map<String, dynamic>> updated = const [],
  int lastRead = 0,
  bool muted = false,
  bool canModerate = false,
  String serverTime = '2026-10-29T10:00:00.123Z',
}) =>
    {
      'messages': messages,
      'has_more': hasMore,
      'updated': updated,
      'last_read_seq': lastRead,
      'muted': muted,
      'can_moderate': canModerate,
      'server_time': serverTime,
    };

Map<String, dynamic> _status({int unread = 0, bool muted = false, int lastRead = 0}) =>
    {'unread_count': unread, 'muted': muted, 'last_read_seq': lastRead};

const _png = <int>[
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
  0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
  0x00, 0x03, 0x01, 0x01, 0x00, 0xc9, 0xfe, 0x92, 0xef, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
  0x44, 0xae, 0x42, 0x60, 0x82,
];

typedef _Harness = ({_SwitchableAdapter adapter, ProviderContainer container, _MemoryChatCache cache});

Future<ApiClient> _client(HttpClientAdapter adapter) async {
  final dio = Dio(BaseOptions(baseUrl: AppConfig.apiBaseUrl + AppConfig.apiPrefix));
  dio.httpClientAdapter = adapter;
  return ApiClient.test(dio);
}

ProviderContainer _container(ApiClient client, {User? user, _MemoryChatCache? cache, ChatPhotoPicker? picker}) =>
    ProviderContainer(overrides: [
      apiClientProvider.overrideWithValue(client),
      authControllerProvider.overrideWith(() => _Auth(user)),
      chatCacheProvider.overrideWithValue(cache ?? _MemoryChatCache()),
      if (picker != null) chatPhotoPickerProvider.overrideWithValue(picker),
    ]);

Widget _app(ProviderContainer container, Widget home, {double textScale = 1.0}) => UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        locale: const Locale('tr', 'TR'),
        supportedLocales: const [Locale('tr', 'TR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: home,
      ),
    );

Future<_Harness> _pumpChat(
  WidgetTester tester,
  Map<String, List<ScriptedResponse>> script, {
  User? user,
  _MemoryChatCache? cache,
  bool offline = false,
  Size size = const Size(400, 800),
  double textScale = 1.0,
  ChatPhotoPicker? picker,
}) async {
  final adapter = _SwitchableAdapter(FakeHttpClientAdapter(script: script))..offline = offline;
  final memory = cache ?? _MemoryChatCache();
  final container = _container(await _client(adapter), user: user ?? _user(), cache: memory, picker: picker);
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(container, const ChatScreen(), textScale: textScale));
  await _flush(tester);
  return (adapter: adapter, container: container, cache: memory);
}

int _count(List<String> calls, String path) => calls.where((c) => c == path).length;

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  group('ekran', () {
    testWidgets('mesajlar alttan yukarı; kendi sağda, yazar adı, gün ayracı, silinen, okunmamış ayracı', (tester) async {
      final now = clock.now();
      final h = await _pumpChat(tester, {
        _list: [
          (
            status: 200,
            body: _page([
              _msg(4, own: true, text: 'Tamam, geliyorum', at: now),
              _msg(3, deleted: true, at: now),
              _msg(2, text: "Beton saat 8'de", at: now),
              _msg(1, author: 'u-ayse', name: 'Ayşe Sahip', text: 'Günaydın', at: now.subtract(const Duration(days: 1))),
            ], lastRead: 1),
          ),
        ],
        _read: [(status: 200, body: _status(lastRead: 4))],
      });

      expect(find.text('Dün'), findsOneWidget);
      expect(find.text('Bugün'), findsOneWidget);
      expect(find.text('Mesaj silindi'), findsOneWidget);
      expect(find.text('Okunmamış mesajlar'), findsOneWidget);
      expect(find.text('Ayşe Sahip'), findsOneWidget);
      // Mehmet'in iki ardışık mesajında ad bir kez.
      expect(find.text('Mehmet Usta'), findsOneWidget);
      expect(find.text('Ahmet Saha'), findsNothing, reason: 'kendi mesajında ad yazmaz');

      // Alttan yukarı: en eski en üstte, en yeni en altta.
      final y = [for (final t in ['Günaydın', "Beton saat 8'de", 'Tamam, geliyorum']) tester.getTopLeft(find.text(t)).dy];
      expect(y[0] < y[1] && y[1] < y[2], isTrue, reason: '$y');
      expect(tester.getTopLeft(find.text('Okunmamış mesajlar')).dy, lessThan(y[1]));
      // Kendi mesajı sağda, başkasınınki solda.
      expect(tester.getTopRight(find.text('Tamam, geliyorum')).dx, greaterThan(300));
      expect(tester.getTopLeft(find.text('Günaydın')).dx, lessThan(100));

      // Görünürken okundu: görülen en yeni mesaja kadar.
      final i = h.adapter.inner.calls.indexOf(_read);
      expect(i, isNot(-1));
      expect(h.adapter.inner.requestBodies[i], {'seq': 4});
      // Önbelleğe yazıldı.
      expect(h.cache.snapshots['u-ahmet']?.messages.map((m) => m.seq), [4, 3, 2, 1]);
    });

    testWidgets('boş grup; Türkçe metin gönderilir (client_id ile), yazma alanı temizlenir', (tester) async {
      // GET (liste) ve POST (gönder) aynı yola gider: yanıtlar sırayla.
      final h = await _pumpChat(tester, {
        _list: [
          (status: 200, body: _page([])),
          (status: 201, body: _msg(1, own: true, text: 'Şantiyede ığdır çimentosu çok güzel')),
        ],
      });
      expect(find.text('Henüz mesaj yok'), findsOneWidget);
      // Gönder boşken kapalı.
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send)).onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'Şantiyede ığdır çimentosu çok güzel');
      await tester.pump();
      await tester.tap(find.byTooltip('Gönder'));
      await _flush(tester);

      expect(find.text('Şantiyede ığdır çimentosu çok güzel'), findsOneWidget);
      expect(find.text('Gönderiliyor…'), findsNothing);
      expect(find.text('Henüz mesaj yok'), findsNothing);
      final post = h.adapter.inner.methods.indexOf('POST');
      final body = h.adapter.inner.requestBodies[post] as Map;
      expect(body['text'], 'Şantiyede ığdır çimentosu çok güzel');
      expect(body['client_id'], matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    });

    testWidgets('gönderilemeyen mesaj: "Tekrar dene" aynı client_id ile gider; "Vazgeç" siler', (tester) async {
      final h = await _pumpChat(tester, {
        _list: [
          (status: 200, body: _page([])),
          // Tekrar denemenin yanıtı (ilk deneme bağlantısız, kuyruğa uğramaz).
          (status: 201, body: _msg(1, own: true, text: 'Malzeme geldi')),
        ],
      });
      h.adapter.offline = true;
      await tester.enterText(find.byType(TextField), 'Malzeme geldi');
      await tester.pump();
      await tester.tap(find.byTooltip('Gönder'));
      await _flush(tester);
      expect(find.text('Malzeme geldi'), findsOneWidget);
      expect(find.textContaining('Gönderilemedi (Bağlantı yok) · Tekrar dene'), findsOneWidget);
      final firstId = (h.adapter.offlineBodies.single as Map)['client_id'];

      h.adapter.offline = false;
      await tester.tap(find.text('Malzeme geldi'));
      await _flush(tester);
      await tester.tap(find.text('Tekrar dene'));
      await _flush(tester);
      expect(find.textContaining('Gönderilemedi'), findsNothing);
      expect(find.text('Malzeme geldi'), findsOneWidget);
      final retried = h.adapter.inner.requestBodies[h.adapter.inner.methods.indexOf('POST')] as Map;
      expect(retried['client_id'], firstId, reason: 'tekrar deneme ikinci mesaj yazmasın');

      // İkinci mesaj gönderilemez ve vazgeçilir: hiç gitmez.
      h.adapter.offline = true;
      await tester.enterText(find.byType(TextField), 'Vazgeçilecek');
      await tester.pump();
      await tester.tap(find.byTooltip('Gönder'));
      await _flush(tester);
      await tester.longPress(find.text('Vazgeçilecek'));
      await _flush(tester);
      await tester.tap(find.text('Vazgeç'));
      await _flush(tester);
      expect(find.text('Vazgeçilecek'), findsNothing);
    });

    testWidgets('5 sn yoklama: after + changed_since; yeni mesaj ve silinen düşer; arka planda durur', (tester) async {
      final now = clock.now();
      final h = await _pumpChat(tester, {
        _list: [
          (status: 200, body: _page([_msg(2, own: true, text: 'Ben', at: now), _msg(1, text: 'İlk', at: now)], lastRead: 2)),
          (
            status: 200,
            body: _page(
              [_msg(3, text: 'Yeni mesaj geldi', at: now)],
              updated: [_msg(1, deleted: true, at: now)],
              lastRead: 2,
              serverTime: '2026-10-29T10:00:05.000Z',
            ),
          ),
          (status: 200, body: _page([], serverTime: '2026-10-29T10:00:10.000Z')),
          (status: 200, body: _page([], serverTime: '2026-10-29T10:00:30.000Z')),
        ],
        _read: [(status: 200, body: _status(lastRead: 3))],
      });
      final calls = h.adapter.inner.calls;
      expect(_count(calls, _list), 1, reason: 'açılış tek istek (ilk yoklama açılışla çakışmaz)');
      expect(calls, isNot(contains(_read)), reason: 'okunmamış yokken okundu isteği yok');

      await tester.pump(ChatScreen.pollInterval);
      await _flush(tester);
      expect(_count(calls, _list), 2);
      final q = h.adapter.inner.requestQueries[calls.lastIndexOf(_list)];
      expect(q['after'], 2);
      expect(q['changed_since'], '2026-10-29T10:00:00.123Z');
      expect(find.text('Yeni mesaj geldi'), findsOneWidget);
      expect(find.text('İlk'), findsNothing);
      expect(find.text('Mesaj silindi'), findsOneWidget);
      expect(h.adapter.inner.requestBodies[calls.indexOf(_read)], {'seq': 3});
      // Okundu rozet/zil sağlayıcılarını yalnızca tazeler; kimse izlemezken
      // zil listesini indirmez.
      expect(calls, isNot(contains('/notifications')));
      expect(calls, isNot(contains('/organization/chat/status')));

      await tester.pump(ChatScreen.pollInterval);
      await _flush(tester);
      expect(_count(calls, _list), 3);
      expect(h.adapter.inner.requestQueries[calls.lastIndexOf(_list)]['after'], 3);

      // Arka planda yoklama yok; öne gelince hemen. (Test bağlayıcısı ara
      // durumları kendisi üretmez -- telefondaki sıra elle verilir.)
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump(const Duration(seconds: 20));
      expect(_count(calls, _list), 3);
      for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await _flush(tester);
      expect(_count(calls, _list), 4);
    });

    testWidgets('başka sekmeye geçince (dal arka planda) yoklamaz, okundu demez; dönünce hemen yoklar', (tester) async {
      final now = clock.now();
      final adapter = _SwitchableAdapter(FakeHttpClientAdapter(script: {
        _list: [
          (status: 200, body: _page([_msg(1, text: 'İlk', at: now)], lastRead: 1)),
          (status: 200, body: _page([_msg(2, text: 'Sekme dönüşü', at: now)], lastRead: 1)),
        ],
        _read: [(status: 200, body: _status(lastRead: 2))],
      }));
      final container = _container(await _client(adapter), user: _user());
      addTearDown(container.dispose);
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // go_router'ın StatefulShellRoute'u arka plandaki dalı böyle tutar.
      await tester.pumpWidget(_app(
        container,
        ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (_, on, child) => TickerMode(enabled: on, child: child!),
          child: const ChatScreen(),
        ),
      ));
      await _flush(tester);
      final calls = adapter.inner.calls;
      expect(_count(calls, _list), 1);

      active.value = false;
      await _flush(tester);
      await tester.pump(const Duration(seconds: 12));
      expect(_count(calls, _list), 1, reason: 'görünmeyen sohbet yoklamaz');

      active.value = true;
      await _flush(tester);
      expect(_count(calls, _list), 2);
      expect(find.text('Sekme dönüşü'), findsOneWidget);
      expect(adapter.inner.requestBodies[calls.indexOf(_read)], {'seq': 2});
    });

    testWidgets('bağlantı yok: kaydedilen mesajlar + bant; bağlantı gelince yenilenir', (tester) async {
      final cache = _MemoryChatCache();
      final now = clock.now();
      cache.snapshots['u-ahmet'] = ChatSnapshot(
        organizationId: 'org-1',
        messages: [ChatMessage.fromJson(_msg(1, text: 'Önbellekteki mesaj', at: now))],
        lastReadSeq: 1,
      );
      final h = await _pumpChat(tester, {
        _list: [(status: 200, body: _page([_msg(2, text: 'Sunucudan taze', at: now), _msg(1, text: 'Önbellekteki mesaj', at: now)], lastRead: 2))],
      }, cache: cache, offline: true);
      expect(find.text('Önbellekteki mesaj'), findsOneWidget);
      expect(find.text('Bağlantı yok. Son kaydedilen mesajlar gösteriliyor.'), findsOneWidget);

      h.adapter.offline = false;
      await tester.pump(ChatScreen.pollInterval);
      await _flush(tester);
      expect(find.text('Sunucudan taze'), findsOneWidget);
      expect(find.textContaining('Bağlantı yok'), findsNothing);
    });

    testWidgets('önbellek yokken bağlantı yok: hata ve Tekrar Dene', (tester) async {
      await _pumpChat(tester, {}, offline: true);
      expect(find.text('Bağlantı kurulamadı. İnternet bağlantınızı kontrol edin.'), findsOneWidget);
      expect(find.text('Tekrar Dene'), findsOneWidget);
    });

    testWidgets('uzun bas: kendi mesajı onayla silinir ("Mesaj silindi"); başkasınınki yalnızca kopyalanır', (tester) async {
      final h = await _pumpChat(tester, {
        _list: [
          (
            status: 200,
            body: _page([_msg(2, own: true, text: 'Yanlış mesaj'), _msg(1, text: 'Başkasının mesajı')], lastRead: 2),
          ),
        ],
        '$_list/m2': [(status: 200, body: _msg(2, own: true, deleted: true))],
      });
      await tester.longPress(find.text('Başkasının mesajı'));
      await _flush(tester);
      expect(find.text('Metni kopyala'), findsOneWidget);
      expect(find.text('Sil'), findsNothing);
      await tester.tapAt(const Offset(200, 100));
      await _flush(tester);

      await tester.longPress(find.text('Yanlış mesaj'));
      await _flush(tester);
      await tester.tap(find.text('Sil'));
      await _flush(tester);
      expect(find.text('Mesaj silinsin mi?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Sil'));
      await _flush(tester);
      expect(h.adapter.inner.methods[h.adapter.inner.calls.indexOf('$_list/m2')], 'DELETE');
      expect(find.text('Yanlış mesaj'), findsNothing);
      expect(find.text('Mesaj silindi'), findsOneWidget);
    });

    testWidgets('yönetici başkasının mesajını da silebilir (can_delete)', (tester) async {
      await _pumpChat(tester, {
        _list: [(status: 200, body: _page([_msg(1, text: 'Uygunsuz', canDelete: true)], lastRead: 1, canModerate: true))],
        '$_list/m1': [(status: 200, body: _msg(1, deleted: true))],
      });
      await tester.longPress(find.text('Uygunsuz'));
      await _flush(tester);
      await tester.tap(find.text('Sil'));
      await _flush(tester);
      expect(find.textContaining('Mehmet Usta kişisinin mesajı'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Sil'));
      await _flush(tester);
      expect(find.text('Mesaj silindi'), findsOneWidget);
    });

    testWidgets('menü: Bildirimleri sessize al / aç', (tester) async {
      final h = await _pumpChat(tester, {
        _list: [(status: 200, body: _page([_msg(1, text: 'x')], lastRead: 1))],
        '/organization/chat/mute': [
          (status: 200, body: _status(muted: true, lastRead: 1)),
          (status: 200, body: _status(lastRead: 1)),
        ],
      });
      await tester.tap(find.byTooltip('Seçenekler'));
      await _flush(tester);
      await tester.tap(find.text('Bildirimleri sessize al'));
      await _flush(tester);
      expect(h.adapter.inner.requestBodies[h.adapter.inner.calls.indexOf('/organization/chat/mute')], {'muted': true});
      expect(find.text('Firma Grubu bildirimleri sessize alındı.'), findsOneWidget);
      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);

      await tester.tap(find.byTooltip('Seçenekler'));
      await _flush(tester);
      await tester.tap(find.text('Bildirimleri aç'));
      await _flush(tester);
      expect(find.byIcon(Icons.notifications_off_outlined), findsNothing);
    });

    testWidgets('fotoğraf mesajı: küçük resim oturumlu indirilir, önbelleğe yazılır; dokununca tam ekran', (tester) async {
      final h = await _pumpChat(tester, {
        _list: [(status: 200, body: _page([_msg(1, photo: true, text: 'Kolon donatısı')], lastRead: 1))],
        '$_list/m1/photo': [(status: 200, body: _png)],
      });
      expect(find.text('Kolon donatısı'), findsOneWidget);
      expect(h.adapter.inner.calls, contains('$_list/m1/photo'));
      expect(h.cache.photos['m1'], _png);
      expect(find.byType(Image), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Fotoğraf, büyütmek için dokun'));
      await _flush(tester);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('Mehmet Usta'), findsWidgets);
      // İkinci açılış önbellekten: yeniden indirme yok.
      expect(_count(h.adapter.inner.calls, '$_list/m1/photo'), 1);
    });

    testWidgets('fotoğraf ekle: kamera/galeri sayfası; vazgeçilirse ve 25 MB üstünde gönderim yok', (tester) async {
      final picker = _FakePicker();
      final h = await _pumpChat(tester, {
        _list: [(status: 200, body: _page([]))],
      }, picker: picker);
      await tester.tap(find.byTooltip('Fotoğraf gönder'));
      await _flush(tester);
      expect(find.text('Fotoğraf çek'), findsOneWidget);
      await tester.tap(find.text('Galeriden seç'));
      await _flush(tester);
      expect(find.textContaining('Gönderiliyor'), findsNothing);

      picker.next = (path: '/yok/buyuk.jpg', name: 'buyuk.jpg', size: AppConfig.maxUploadBytes + 1);
      await tester.tap(find.byTooltip('Fotoğraf gönder'));
      await _flush(tester);
      await tester.tap(find.text('Fotoğraf çek'));
      await _flush(tester);
      expect(find.text("Fotoğraf 25 MB'tan büyük olamaz."), findsOneWidget);
      expect(h.adapter.inner.calls, isNot(contains('$_list/photo')));
    });

    testWidgets('320 pt telefon + büyük yazı: taşma yok', (tester) async {
      final long = 'Yarın sabah 07:30 şantiye girişinde toplanıyoruz, baretler ve emniyet kemerleri unutulmasın. ' * 3;
      final h = await _pumpChat(tester, {
        _list: [
          (
            status: 200,
            body: _page([
              _msg(3, own: true, text: long),
              _msg(2, name: 'Çok Uzun İsimli Şantiye Şefi Mühendis Hüseyin Öztürkmenoğlu', text: long),
              _msg(1, deleted: true),
            ], lastRead: 3, muted: true),
          ),
        ],
      }, size: const Size(320, 568), textScale: 2.0);
      expect(tester.takeException(), isNull);
      h.adapter.offline = true;
      await tester.enterText(find.byType(TextField), 'Gönderilemeyecek uzun bir mesaj metni');
      await tester.pump();
      await tester.tap(find.byTooltip('Gönder'));
      await _flush(tester);
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
    });
  });

  group('denetleyici', () {
    test('fotoğraf gönderimi: multipart (file + client_id), yanıt listeye girer', () async {
      final dir = await Directory.systemTemp.createTemp('firma-grubu-test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/IMG_0001.jpg')..writeAsBytesSync(_png);
      final adapter = FakeHttpClientAdapter(script: {
        _list: [(status: 200, body: _page([], lastRead: 0))],
        '$_list/photo': [(status: 201, body: _msg(1, own: true, photo: true))],
      });
      final container = _container(await buildFakeApiClient(adapter), user: _user());
      addTearDown(container.dispose);
      final sub = container.listen(chatControllerProvider, (_, _) {});
      addTearDown(sub.close);
      await _settle(() => container.read(chatControllerProvider).loadedFromServer);

      final problem = await container
          .read(chatControllerProvider.notifier)
          .sendPhoto((path: file.path, name: 'IMG_0001.jpg', size: null));
      expect(problem, isNull);
      await _settle(() => container.read(chatControllerProvider).pending.isEmpty);
      final form = adapter.requestBodies[adapter.calls.indexOf('$_list/photo')] as FormData;
      expect(form.files.single.key, 'file');
      expect(form.files.single.value.filename, 'IMG_0001.jpg');
      final fields = {for (final f in form.fields) f.key: f.value};
      expect(fields['client_id'], isNotEmpty);
      expect(container.read(chatControllerProvider).messages.single.photo?.mimeType, 'image/png');
    });

    test("25 MB'ı aşan fotoğraf hiç gönderilmez", () async {
      final adapter = FakeHttpClientAdapter(script: {
        _list: [(status: 200, body: _page([]))],
      });
      final container = _container(await buildFakeApiClient(adapter), user: _user());
      addTearDown(container.dispose);
      final sub = container.listen(chatControllerProvider, (_, _) {});
      addTearDown(sub.close);
      await _settle(() => container.read(chatControllerProvider).loadedFromServer);
      final problem = await container
          .read(chatControllerProvider.notifier)
          .sendPhoto((path: '/yok.jpg', name: 'buyuk.jpg', size: AppConfig.maxUploadBytes + 1));
      expect(problem, "Fotoğraf 25 MB'tan büyük olamaz.");
      expect(adapter.calls, isNot(contains('$_list/photo')));
      expect(container.read(chatControllerProvider).pending, isEmpty);
    });

    test('uzun kopukluktan sonra yoklama sayfaları sırayla alır (has_more)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        _list: [
          (status: 200, body: _page([_msg(1, text: 'a')], lastRead: 1)),
          (status: 200, body: _page([_msg(3, text: 'c'), _msg(2, text: 'b')], hasMore: true, lastRead: 1)),
          (status: 200, body: _page([_msg(4, text: 'd')], lastRead: 1)),
        ],
      });
      final container = _container(await buildFakeApiClient(adapter), user: _user());
      addTearDown(container.dispose);
      final sub = container.listen(chatControllerProvider, (_, _) {});
      addTearDown(sub.close);
      await _settle(() => container.read(chatControllerProvider).loadedFromServer);
      await container.read(chatControllerProvider.notifier).poll();
      expect(container.read(chatControllerProvider).messages.map((m) => m.seq), [4, 3, 2, 1]);
      expect([for (final q in adapter.requestQueries.skip(1)) q['after']], [1, 3]);
      // changed_since yalnızca ilk sayfada.
      expect(adapter.requestQueries[2].containsKey('changed_since'), isFalse);
    });

    test('kendi gönderdiğim mesaj yoklama imlecini atlatmaz (hemen önce yazılan mesaj kaybolmaz)', () async {
      // GET (açılış) -> POST (benim 42) -> GET (yoklama): aynı yol, sırayla.
      final adapter = FakeHttpClientAdapter(script: {
        _list: [
          (status: 200, body: _page([_msg(40, text: 'kırk')], lastRead: 40)),
          (status: 201, body: _msg(42, own: true, text: 'benim')),
          (status: 200, body: _page([_msg(42, own: true, text: 'benim'), _msg(41, text: 'hemen önce yazılan')], lastRead: 42)),
        ],
      });
      final container = _container(await buildFakeApiClient(adapter), user: _user());
      addTearDown(container.dispose);
      final sub = container.listen(chatControllerProvider, (_, _) {});
      addTearDown(sub.close);
      await _settle(() => container.read(chatControllerProvider).loadedFromServer);
      final chat = container.read(chatControllerProvider.notifier);
      await chat.send('benim');
      expect(container.read(chatControllerProvider).maxSeq, 42);
      await chat.poll();
      expect(adapter.requestQueries.last['after'], 40, reason: 'imleç sunucu sayfasından ilerler');
      expect(container.read(chatControllerProvider).messages.map((m) => m.seq), [42, 41, 40]);
    });

    test('başka firmanın önbelleği gösterilmez', () async {
      final cache = _MemoryChatCache()
        ..snapshots['u-ahmet'] = ChatSnapshot(
          organizationId: 'baska-firma',
          messages: [ChatMessage.fromJson(_msg(9, text: 'eski firma'))],
        );
      final adapter = FakeHttpClientAdapter(script: {});
      final container = _container(await buildFakeApiClient(adapter), user: _user(), cache: cache);
      addTearDown(container.dispose);
      final sub = container.listen(chatControllerProvider, (_, _) {});
      addTearDown(sub.close);
      await _settle(() => !container.read(chatControllerProvider).initialLoading);
      expect(container.read(chatControllerProvider).messages, isEmpty);
    });

    test('gün ayracı metni', () {
      final now = DateTime.utc(2026, 10, 29, 9); // İstanbul 12:00
      expect(chatDayLabel(chatDayOf(now), now), 'Bugün');
      expect(chatDayLabel(chatDayOf(now.subtract(const Duration(days: 1))), now), 'Dün');
      expect(chatDayLabel(DateTime.utc(2026, 10, 12), now), '12 Ekim Pazartesi');
      expect(chatDayLabel(DateTime.utc(2025, 3, 4), now), '4 Mart 2025');
      // UTC 22:30 = İstanbul ertesi gün 01:30.
      expect(chatDay('2026-10-28T22:30:00Z'), DateTime.utc(2026, 10, 29));
      expect(chatTime('2026-10-28T22:30:00Z'), '01:30');
      expect(chatBadgeLabel(7), '7');
      expect(chatBadgeLabel(1000), '99+');
    });
  });

  group('girişler', () {
    Future<FakeHttpClientAdapter> pumpEntry(WidgetTester tester, User user, {int unread = 3}) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/organization/chat/status': [for (var i = 0; i < 3; i++) (status: 200, body: _status(unread: unread))],
      });
      final container = _container(await buildFakeApiClient(adapter), user: user);
      addTearDown(container.dispose);
      final router = GoRouter(routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(appBar: AppBar(title: const Text('Ana Sayfa'), actions: const [ChatAppBarButton()])),
        ),
        GoRoute(path: kChatRoute, builder: (_, _) => const Scaffold(body: Text('sohbet ekranı'))),
      ]);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      await _flush(tester);
      return adapter;
    }

    testWidgets('Ana Sayfa üst çubuğu: rozetli Firma Grubu, dokununca sohbet', (tester) async {
      await pumpEntry(tester, _user());
      expect(find.byTooltip('Firma Grubu, 3 okunmamış'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      await tester.tap(find.byTooltip('Firma Grubu, 3 okunmamış'));
      await _flush(tester);
      expect(find.text('sohbet ekranı'), findsOneWidget);
    });

    testWidgets('100+ okunmamış "99+"', (tester) async {
      await pumpEntry(tester, _user(), unread: 1000);
      expect(find.text('99+'), findsOneWidget);
    });

    testWidgets('izni olmayan ve taşeron hesabı girişi görmez, istek de atılmaz', (tester) async {
      for (final u in [
        _user(permissions: const {'notifications.read'}),
        _user(supplierId: 's1'),
        _user(permissions: const {}),
      ]) {
        final adapter = await pumpEntry(tester, u);
        expect(find.byIcon(Icons.forum_outlined), findsNothing);
        expect(adapter.calls, isNot(contains('/organization/chat/status')));
      }
    });

    testWidgets('Diğer: İş Araçları\'nın başında okunmamış sayısıyla', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/organization/chat/status': [for (var i = 0; i < 3; i++) (status: 200, body: _status(unread: 12))],
      });
      final container = _container(await buildFakeApiClient(adapter),
          user: _user(permissions: const {kPermOrganizationChatUse, 'projects.expenses.create', 'notifications.read'}));
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: OtherMenuScreen()),
      ));
      await _flush(tester);
      expect(find.text('Firma Grubu'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Firma Grubu')).dy, lessThan(tester.getTopLeft(find.text('Masraflar')).dy));
    });

    test('rota: /diger/firma-grubu gerçek yönlendiricide sohbet ekranı', () {
      final container = ProviderContainer(overrides: [authControllerProvider.overrideWith(() => _Auth(_user()))]);
      addTearDown(container.dispose);
      final match = container.read(routerProvider).configuration.findMatch(Uri.parse(kChatRoute));
      expect(match.isError, isFalse);
      expect(match.fullPath, kChatRoute);
    });
  });
}

/// pumpAndSettle tek başına yetmez: hiçbir kare beklenmiyorsa durur, Dio'nun
/// sıfır gecikmeli zamanlayıcıları (Future(...)) ise ancak sahte zaman
/// ilerleyince çalışır -- istek hiç atılmamış olurdu. Sahte zamanı biraz
/// ilerletip öyle yerleşir (5 sn'lik yoklama zamanlayıcısına dokunmaz).
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  await tester.pumpAndSettle();
}

/// Gerçek zamanlı (testWidgets dışı) bekleme: koşul sağlanana kadar.
Future<void> _settle(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue, reason: 'koşul zamanında sağlanmadı');
}
