import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/utils/formatters.dart';
import 'package:arvend/core/widgets/app_filter_bar.dart';
import 'package:arvend/core/widgets/quick_action_button.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/dashboard/data/dashboard_providers.dart';
import 'package:arvend/features/dashboard/domain/dashboard_registry.dart';
import 'package:arvend/features/dashboard/presentation/attention_screen.dart';
import 'package:arvend/features/dashboard/presentation/dashboard_screen.dart';
import 'package:arvend/features/dashboard/presentation/widgets/kpi_grid.dart';
import 'package:arvend/features/dashboard/presentation/widgets/quick_actions_row.dart';
import 'package:arvend/features/projects/presentation/project_detail_screen.dart';

import '../../test_utils/fake_api_client.dart';
import 'fixtures.dart';

/// Ana sayfa davranış testleri (spec §6.8 madde 2): gerçek ApiClient +
/// betikli sahte HTTP adaptörü ('/dashboard', '/notifications/unread-count');
/// kullanıcı fixture personalarından gelir.
class _FakeAuth extends AuthController {
  _FakeAuth(this._user);
  final User _user;

  @override
  Future<User?> build() async => _user;
}

ScriptedResponse _ok(Object body) => (status: 200, body: body);

Map<String, List<ScriptedResponse>> _script(Map<String, dynamic>? fixture, {int unread = 4, int status = 200}) => {
  '/dashboard': [
    (status: status, body: status == 200 ? fixture : {'error': 'sunucu hatası'}),
  ],
  '/notifications/unread-count': [
    _ok({'unread_count': unread}),
  ],
};

GoRouter _router() => GoRouter(
  initialLocation: '/ana-sayfa',
  routes: [
    GoRoute(
      path: '/ana-sayfa',
      builder: (_, _) => const DashboardScreen(),
      routes: [
        GoRoute(
          path: 'dikkat',
          builder: (_, s) => AttentionScreen(initialCode: s.uri.queryParameters['kod']),
        ),
      ],
    ),
    GoRoute(
      path: '/teklifler/:id',
      builder: (_, s) => Scaffold(body: Text('TEKLİF ${s.pathParameters['id']}')),
    ),
    GoRoute(
      path: '/projeler/:id',
      builder: (_, s) => Scaffold(body: Text('PROJE ${s.pathParameters['id']} ${s.uri.query}')),
      routes: [
        GoRoute(
          path: 'taseronlar/:sc/hakedisler/:claim',
          builder: (_, s) => Scaffold(body: Text('HAKEDİŞ ${s.pathParameters['claim']}')),
        ),
        GoRoute(
          path: 'satin-alma/talepler/yeni',
          builder: (_, s) => Scaffold(appBar: AppBar(), body: Text('YENİ TALEP ${s.pathParameters['id']}')),
        ),
      ],
    ),
    // Diğer altındaki yönetim ekranlarının yer tutucusu: açılan tam konum
    // (sorgu dahil) yazılır.
    GoRoute(
      path: '/diger/:a',
      builder: (_, s) => Scaffold(appBar: AppBar(), body: Text('DİĞER ${s.uri}')),
      routes: [
        GoRoute(
          path: ':b',
          builder: (_, s) => Scaffold(appBar: AppBar(), body: Text('DİĞER ${s.uri}')),
        ),
      ],
    ),
  ],
);

Future<FakeHttpClientAdapter> _pump(
  WidgetTester tester, {
  required User user,
  required Map<String, List<ScriptedResponse>> script,
  Size size = const Size(400, 1600),
  double textScale = 1.0,
  bool settle = true,
}) async {
  final adapter = FakeHttpClientAdapter(script: script);
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => _FakeAuth(user)),
      ],
      child: MaterialApp.router(
        routerConfig: _router(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return adapter;
}

List<String> _allText(WidgetTester tester) => [
  for (final e in find.byType(RichText).evaluate()) (e.widget as RichText).text.toPlainText(),
];

int _count(List<String> calls, String path) => calls.where((c) => c == path).length;

/// Ana sayfanın dikey kaydırıcısında hedef görünene kadar kaydırır.
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    300,
    scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('personalar', () {
    testWidgets('sahip: bantlar, 4 KPI, Nakit Akışı, tek istek', (tester) async {
      final adapter = await _pump(tester, user: ownerUser, script: _script(fixtureJson('owner')));

      for (final band in ['NAKİT & SATIŞ', 'PROJE & SAHA', 'TEDARİK & MALİYET', 'FİRMA KAYITLARI']) {
        expect(find.text(band), findsOneWidget, reason: band);
      }
      for (final label in ['Açık alacak', 'Bu ay net nakit', 'Teklif hattı', 'Proje nakit dengesi']) {
        expect(
          find.descendant(of: find.byType(KpiGrid), matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
      }
      expect(find.text('Nakit Akışı'), findsOneWidget);
      expect(find.text('Merhaba, Taha'), findsOneWidget);
      expect(find.text('Arvend Yapı'), findsOneWidget);
      expect(find.text('Bugün 13 iş senin sıranda; 7 tanesi acil.'), findsOneWidget);
      expect(find.descendant(of: find.byType(KpiGrid), matching: find.text('5,1 Mn TL')), findsOneWidget);
      // Diğer para biriminin AÇIK ALACAĞI: KPI kutusu ve Proje Finansı
      // kartı aynı değeri gösterir (portföy değeri 120.000 $ DEĞİL).
      expect(find.text('Diğer: 45.000 \$'), findsNWidgets(2));
      expect(find.text('Diğer: 120.000 \$'), findsNothing);
      expect(find.text('Tümü (18)'), findsOneWidget);
      // Eski üç çağrı (/projects, /tasks/mine) YOK -- tek özet ucu.
      expect(adapter.calls, isNot(contains('/projects')));
      expect(adapter.calls, isNot(contains('/tasks/mine')));
      expect(_count(adapter.calls, '/dashboard'), 1);
      // Mobilde bildirim kartı yok (zil yeterli).
      expect(find.text('Bildirimler'), findsNothing);
    });

    testWidgets('finans: Görevler kartı ve /tasks/mine yok, Tahsilat Gir var', (tester) async {
      final adapter = await _pump(tester, user: financeUser, script: _script(fixtureJson('finance')));

      expect(find.text('Görevler'), findsNothing);
      expect(adapter.calls, isNot(contains('/tasks/mine')));
      expect(find.text('Tahsilat Gir'), findsOneWidget);
      expect(find.text('Masraf Gir'), findsOneWidget);
      expect(find.text('Satın Alma Talebi'), findsOneWidget);
      expect(find.text('Teklif Oluştur'), findsNothing);
      expect(find.text('Üyesi olduğun 3 projenin verileri gösteriliyor.'), findsOneWidget);
      // Onaylar "Senin sıran"da.
      expect(find.text('SENİN SIRAN'), findsOneWidget);
      expect(find.text('Nakit Akışı'), findsOneWidget);
      for (final band in ['NAKİT & SATIŞ', 'PROJE & SAHA', 'TEDARİK & MALİYET', 'FİRMA KAYITLARI']) {
        expect(find.text(band), findsOneWidget, reason: band);
      }
    });

    testWidgets('saha: Nakit Akışı yok, Görevlerim var, BÖLÜMLER, yalnızca "Not Ekle", hiç para yok', (tester) async {
      await _pump(tester, user: fieldUser, script: _script(fixtureJson('field')));

      expect(find.text('Nakit Akışı'), findsNothing);
      expect(find.text('Görevlerim'), findsOneWidget);
      expect(find.text('BÖLÜMLER'), findsOneWidget);
      expect(find.text('NAKİT & SATIŞ'), findsNothing);
      expect(find.text('Not Ekle'), findsOneWidget);
      for (final a in QuickActionKey.values.where((a) => a != QuickActionKey.note)) {
        expect(find.text(a.label), findsNothing, reason: a.label);
      }
      final money = RegExp(r'(\bTL\b|\$|€)');
      final leaks = _allText(tester).where(money.hasMatch).toList();
      expect(leaks, isEmpty, reason: 'saha kullanıcısına para gösterilmemeli: $leaks');
    });

    testWidgets('yeni firma: kurulum rehberi + proje modülleri, KPI yok; Gizle/Göster', (tester) async {
      await _pump(tester, user: emptyOwnerUser, script: _script(fixtureJson('empty_company')));

      expect(find.text('Kurulum — ilk adımlar'), findsOneWidget);
      expect(find.text('1 / 6 tamamlandı'), findsOneWidget);
      expect(find.text('628 ürün'), findsWidgets);
      expect(find.text('Proje modülleri'), findsOneWidget);
      expect(find.byType(KpiGrid), findsNothing);
      expect(find.text('Dikkat Gerektirenler'), findsNothing);
      // Dikkat gizliyken fiyat kaynağı uyarısı kayıtlar kartının altında.
      expect(find.text('Demir Profil fiyat kaynağı hiç senkronlanmadı'), findsOneWidget);

      await tester.tap(find.text('Gizle'));
      await tester.pumpAndSettle();
      expect(find.text('Kurulum — ilk adımlar'), findsNothing);
      expect(find.text('Kurulum rehberi gizlendi'), findsOneWidget);
      expect(find.byType(KpiGrid), findsOneWidget);
      expect(find.text('Dikkat Gerektirenler'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('arvend.home.onboarding.hidden.${emptyOwnerUser.organizationId}.${emptyOwnerUser.id}'),
        '1',
      );

      await tester.tap(find.text('Göster'));
      await tester.pumpAndSettle();
      expect(find.text('Kurulum — ilk adımlar'), findsOneWidget);
    });
  });

  group('hata durumları', () {
    testWidgets('bölüm hatası: tek satır içi hata, diğer kartlar sağlam, Dikkat notu', (tester) async {
      final json = fixtureJson('owner');
      (json['sections'] as Map<String, dynamic>).remove('procurement');
      json['section_errors'] = {'procurement': 'section_failed'};
      await _pump(tester, user: ownerUser, script: _script(json));

      expect(find.text('Bu özet şu an yüklenemedi.'), findsOneWidget);
      expect(find.text('Satın Alma'), findsOneWidget); // kart başlığı kalır
      expect(find.text('Bazı bölümler yüklenemedi; liste eksik olabilir.'), findsOneWidget);
      expect(find.text('Proje Finansı'), findsOneWidget);
      expect(find.text('Taşeron'), findsOneWidget);
    });

    testWidgets('tüm istek başarısız: karşılama + hata kartı + hızlı işlemler + Kısayollar', (tester) async {
      await _pump(tester, user: ownerUser, script: _script(null, status: 500));

      expect(find.text('Merhaba, Taha'), findsOneWidget);
      expect(find.text('Özet yüklenemedi'), findsOneWidget);
      expect(find.text('Kısayollar'), findsOneWidget);
      expect(find.text('Teklif Oluştur'), findsOneWidget);
      expect(find.text('Projeler'), findsOneWidget);
    });

    testWidgets('yenileme başarısızsa eski veri kalır, üstte "Güncellenemedi" bandı', (tester) async {
      final adapter = await _pump(
        tester,
        user: ownerUser,
        script: {
          '/dashboard': [
            _ok(fixtureJson('owner')),
            (status: 500, body: {'error': 'sunucu hatası'}),
          ],
          '/notifications/unread-count': [
            _ok({'unread_count': 4}),
            _ok({'unread_count': 4}),
          ],
        },
      );
      await tester.fling(find.byType(CustomScrollView), const Offset(0, 500), 1500);
      await tester.pumpAndSettle();

      expect(_count(adapter.calls, '/dashboard'), 2);
      expect(find.text('Güncellenemedi · son veri 09:41'), findsOneWidget);
      expect(find.descendant(of: find.byType(KpiGrid), matching: find.text('Açık alacak')), findsOneWidget);
    });
  });

  group('yenileme', () {
    testWidgets('aşağı çekince yeniden ister (pull-to-refresh)', (tester) async {
      final owner = fixtureJson('owner');
      final adapter = await _pump(
        tester,
        user: ownerUser,
        script: {
          '/dashboard': [_ok(owner), _ok(owner)],
          '/notifications/unread-count': [
            _ok({'unread_count': 4}),
            _ok({'unread_count': 3}),
          ],
        },
      );
      await tester.fling(find.byType(CustomScrollView), const Offset(0, 500), 1500);
      await tester.pumpAndSettle();
      expect(_count(adapter.calls, '/dashboard'), 2);
      expect(_count(adapter.calls, '/notifications/unread-count'), 2);
    });

    testWidgets('Ana Sayfa sekmesine tekrar dokunulunca yeniler', (tester) async {
      final owner = fixtureJson('owner');
      final adapter = await _pump(
        tester,
        user: ownerUser,
        script: {
          '/dashboard': [_ok(owner), _ok(owner)],
          '/notifications/unread-count': [
            _ok({'unread_count': 4}),
            _ok({'unread_count': 4}),
          ],
        },
      );
      final container = ProviderScope.containerOf(tester.element(find.byType(DashboardScreen)));
      container.read(homeTabReselectProvider.notifier).state++;
      await tester.pumpAndSettle();
      expect(_count(adapter.calls, '/dashboard'), 2);
    });
  });

  group('gezinme', () {
    testWidgets('tek kayıtlı Dikkat satırı kaydın ekranını açar', (tester) async {
      await _pump(tester, user: ownerUser, script: _script(fixtureJson('owner')));

      await tester.tap(find.text('1 teklifin süresi doldu, müşteri yanıt vermedi').first);
      await tester.pumpAndSettle();
      expect(find.text('TEKLİF 10000000-0000-4000-8000-000000000031'), findsOneWidget);
    });

    testWidgets('kayıt ekranından dönülünce ana sayfa tazelenir (orada yapılan işlem bayat kalmasın)', (tester) async {
      final adapter = await _pump(
        tester,
        user: ownerUser,
        script: {
          ..._script(fixtureJson('owner')),
          '/dashboard': [_ok(fixtureJson('owner')), _ok(fixtureJson('owner'))],
          '/notifications/unread-count': [
            _ok({'unread_count': 4}),
            _ok({'unread_count': 4}),
          ],
        },
      );
      expect(_count(adapter.calls, '/dashboard'), 1);

      // Dikkat satırı (tek kayıt) ve kart altı hakediş satırı: ikisi de
      // kaydın ekranına push eder.
      final line = find.text('1 taşeron hakedişi onay bekliyor');
      await _scrollTo(tester, line.last);
      await tester.tap(line.last);
      await tester.pumpAndSettle();
      expect(find.text('HAKEDİŞ 11000000-0000-4000-8000-000000000004'), findsOneWidget);
      expect(_count(adapter.calls, '/dashboard'), 1, reason: 'kayıt açıkken istek yok');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_count(adapter.calls, '/dashboard'), 2);
    });

    testWidgets('tek kayıtlı hakediş satırı (kart altı) tam hakediş ekranını açar', (tester) async {
      await _pump(tester, user: ownerUser, script: _script(fixtureJson('owner')));

      final line = find.text('1 taşeron hakedişi onay bekliyor');
      await _scrollTo(tester, line.last);
      await tester.tap(line.last);
      await tester.pumpAndSettle();
      expect(find.text('HAKEDİŞ 11000000-0000-4000-8000-000000000004'), findsOneWidget);
    });

    testWidgets('FİRMA KAYITLARI satırları yönetim ekranlarını açar (web kartıyla aynı hedef)', (tester) async {
      await _pump(tester, user: ownerUser, script: _script(fixtureJson('owner')));

      const expected = {
        'customers': '/diger/musteriler',
        'employees': '/diger/personel',
        'products': '/diger/urunler/zamlar?period=30',
        'users': '/diger/kullanicilar',
        'calculations': '/diger/metraj-receteleri',
        'suppliers': '/diger/tedarikciler',
        'cost_codes': '/diger/maliyet-kodlari',
      };
      for (final entry in expected.entries) {
        final row = find.byKey(ValueKey('kayit-${entry.key}'));
        await _scrollTo(tester, row);
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.text('DİĞER ${entry.value}'), findsOneWidget, reason: entry.key);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
      // Hiçbir satır web'e yönlendirmiyor -> not yok.
      expect(find.text(kCopyRegistryFooter), findsNothing);
    });

    testWidgets('boş modül kart olarak çizilmez; sondaki "kullanılmayan bölümler" satırından açılır', (tester) async {
      final d = fixtureJson('owner');
      (d['sections'] as Map<String, dynamic>)['suppliers'] = {'active': 0, 'inactive': 0};
      await _pump(tester, user: ownerUser, script: _script(d));

      expect(find.byKey(const ValueKey('kayit-suppliers'), skipOffstage: false), findsNothing);
      expect(find.text('Bekleyen iş yok', skipOffstage: false), findsNothing, reason: 'tekrar eden sessiz satır yok');
      final chip = find.widgetWithText(ActionChip, 'Tedarikçiler');
      await _scrollTo(tester, chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.text('DİĞER /diger/tedarikciler'), findsOneWidget);
    });

    testWidgets('yeni firma: boş satır ve kurulum CTA\'ları Personel/Kullanıcı Ekle ekranlarını açar', (tester) async {
      await _pump(tester, user: emptyOwnerUser, script: _script(fixtureJson('empty_company')));

      for (final (label, location) in [
        ('Personel Ekle', '/diger/personel/yeni'),
        ('Kullanıcı Ekle', '/diger/kullanicilar/yeni'),
      ]) {
        // Kurulum kartı (ilk) ve FİRMA KAYITLARI boş satırı (son) aynı hedef.
        expect(find.text(label), findsNWidgets(2), reason: label);
        for (final which in [find.text(label).first, find.text(label).last]) {
          await _scrollTo(tester, which);
          await tester.tap(which);
          await tester.pumpAndSettle();
          expect(find.text('DİĞER $location'), findsOneWidget, reason: label);
          await tester.pageBack();
          await tester.pumpAndSettle();
        }
      }

      // Kaynağa bağlı dikkat satırı Fiyat Kaynakları ekranını açar.
      final sync = find.text('Demir Profil fiyat kaynağı hiç senkronlanmadı');
      await _scrollTo(tester, sync.last);
      await tester.tap(sync.last);
      await tester.pumpAndSettle();
      expect(find.text('DİĞER /diger/urunler/kaynaklar'), findsOneWidget);
    });

    testWidgets('yönetim CTA\'ları katı kapıdadır: kaba rol admin değilse Kullanıcı Ekle yok', (tester) async {
      final member = User(
        id: emptyOwnerUser.id,
        organizationId: emptyOwnerUser.organizationId,
        username: 'uye',
        fullName: 'Deniz Kara',
        role: UserRole.kullanici,
        isActive: true,
        mustChangePassword: false,
        onboardingCompleted: true,
        onboardingStep: 'completed',
        organizationName: 'Yeni Yapı Ltd.',
        permissions: kAllPermissions.toSet(),
      );
      await _pump(tester, user: member, script: _script(fixtureJson('empty_company')));
      expect(find.text('Kullanıcı Ekle'), findsNothing);
      expect(find.text('Personel Ekle'), findsNWidgets(2));
    });

    testWidgets('çok kayıtlı satır Dikkat listesini o grup açık halde açar', (tester) async {
      await _pump(tester, user: ownerUser, script: _script(fixtureJson('owner')));

      await tester.tap(find.text('4 ödeme planı kaleminin vadesi geçti').first);
      await tester.pumpAndSettle();
      expect(find.byType(AttentionScreen), findsOneWidget);
      expect(find.text('2. Hakediş · Kadıköy Konut Projesi · 21${kNbsp}gün gecikti'), findsOneWidget);
      expect(find.text('350.000,00 TL'), findsOneWidget);
      expect(find.text('+1 daha'), findsOneWidget);

      // Şerit süzgeci: Takipte yalnızca bekleyen ek işi gösterir (çip
      // satırı yatay kaydırılır).
      await tester.dragUntilVisible(find.text('Takipte (2)'), find.byType(AppFilterBar), const Offset(-150, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Takipte (2)'));
      await tester.pumpAndSettle();
      expect(find.text('2 ek iş müşteri onayında'), findsOneWidget);
      expect(find.text('4 ödeme planı kaleminin vadesi geçti'), findsNothing);
    });
  });

  group('dar ekran / büyük yazı', () {
    for (final persona in kDashboardPersonas) {
      testWidgets('$persona 320dp genişlikte taşma yok', (tester) async {
        await _pump(tester, user: userFor(persona), script: _script(fixtureJson(persona)), size: const Size(320, 1600));
        expect(tester.takeException(), isNull);
      });

      testWidgets('$persona 1.6x yazı ölçeğinde taşma yok', (tester) async {
        await _pump(tester, user: userFor(persona), script: _script(fixtureJson(persona)), textScale: 1.6);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Dikkat listesi 320dp + 1.6x yazıda taşma yok', (tester) async {
      await _pump(
        tester,
        user: ownerUser,
        script: _script(fixtureJson('owner')),
        size: const Size(320, 1600),
        textScale: 1.6,
      );
      await _scrollTo(tester, find.text('Tümü (18)'));
      await tester.tap(find.text('Tümü (18)'));
      await tester.pumpAndSettle();
      expect(find.byType(AttentionScreen), findsOneWidget);
      await tester.tap(find.text('4 ödeme planı kaleminin vadesi geçti'));
      await tester.pumpAndSettle();
      expect(find.text('2. Hakediş · Kadıköy Konut Projesi · 21${kNbsp}gün gecikti'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('bölüm hataları (modül dışı paneller)', () {
    testWidgets('finans ve Son Hareketler hesaplanamazsa paneller başlık + hata gövdesiyle kalır', (tester) async {
      final json = fixtureJson('owner');
      final sections = json['sections'] as Map<String, dynamic>;
      sections
        ..remove('finance')
        ..remove('activity');
      json['section_errors'] = {'finance': 'section_failed', 'activity': 'section_failed'};
      await _pump(tester, user: ownerUser, script: _script(json));

      // Nakit Akışı yerinde kalır; Görevlerim üst sıraya TAŞINMAZ.
      expect(find.text('Nakit Akışı'), findsOneWidget);
      expect(find.text('Görevlerim'), findsNothing);
      expect(find.text('Son Hareketler'), findsOneWidget);
      // Proje Finansı kartı + Nakit Akışı + Son Hareketler.
      expect(find.text('Bu özet şu an yüklenemedi.'), findsNWidgets(3));
    });
  });

  group('Dikkat listesi', () {
    testWidgets('yenileme başarısız olsa da liste eski veriyle kalır (tam sayfa hata yok)', (tester) async {
      final failure = (status: 500, body: {'error': 'sunucu hatası'});
      final adapter = await _pump(
        tester,
        user: ownerUser,
        script: {
          '/dashboard': [_ok(fixtureJson('owner')), failure, failure],
          '/notifications/unread-count': [
            for (var i = 0; i < 3; i++) _ok({'unread_count': 4}),
          ],
        },
      );
      // Ana sayfada yenileme başarısız: eski veri + bant.
      await tester.fling(find.byType(CustomScrollView), const Offset(0, 500), 1500);
      await tester.pumpAndSettle();
      expect(find.text('Güncellenemedi · son veri 09:41'), findsOneWidget);

      await tester.tap(find.text('Tümü (18)'));
      await tester.pumpAndSettle();
      expect(find.byType(AttentionScreen), findsOneWidget);
      expect(find.text('4 ödeme planı kaleminin vadesi geçti'), findsOneWidget);
      expect(find.text('Güncellenemedi · son veri 09:41'), findsOneWidget);
      expect(find.text('Beklenmeyen bir hata oluştu.'), findsNothing);

      // Dikkat listesinde aşağı çekip yenileme de başarısız: liste yerinde.
      await tester.fling(
        find.descendant(of: find.byType(AttentionScreen), matching: find.byType(ListView)).first,
        const Offset(0, 500),
        1500,
      );
      await tester.pumpAndSettle();
      expect(_count(adapter.calls, '/dashboard'), 3);
      expect(find.text('4 ödeme planı kaleminin vadesi geçti'), findsOneWidget);
      expect(find.text('Beklenmeyen bir hata oluştu.'), findsNothing);
    });
  });

  group('hızlı işlemler', () {
    Map<String, dynamic> option(String id, String name) => {
      'id': id,
      'project_no': 'PRJ-$id',
      'name': name,
      'customer_name': 'Ali Veli',
      'currency': 'TRY',
      'status': 'active',
    };

    testWidgets('seçici /dashboard/project-options kullanır (GET /projects değil); aynı anda tek işlem', (
      tester,
    ) async {
      final adapter = await _pump(
        tester,
        user: ownerUser,
        script: {
          ..._script(fixtureJson('owner')),
          '/dashboard/project-options': [
            _ok({
              'projects': [option('p1', 'Alfa Konut'), option('p2', 'Beta Ofis')],
            }),
          ],
        },
      );
      final ctx = tester.element(find.byType(QuickActionsRow));
      // Yavaş bağlantıda art arda iki dokunuş: ikincisi kilide takılır.
      unawaited(runQuickAction(ctx, QuickActionKey.collection));
      unawaited(runQuickAction(ctx, QuickActionKey.collection));
      await tester.pump();
      // İşlem sürerken butonlar pasiftir.
      final masraf = tester.widget<QuickActionButton>(find.widgetWithText(QuickActionButton, 'Masraf Gir'));
      expect(masraf.onPressed, isNull);
      await tester.pumpAndSettle();

      expect(_count(adapter.calls, '/dashboard/project-options'), 1);
      expect(adapter.calls, isNot(contains('/projects')));
      expect(find.text('Proje seç'), findsOneWidget);
      expect(find.text('Alfa Konut'), findsOneWidget);

      // Seçici sonuçsuz kapanınca kilit çözülür, özet yeniden istenmez.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Proje seç'), findsNothing);
      final again = tester.widget<QuickActionButton>(find.widgetWithText(QuickActionButton, 'Masraf Gir'));
      expect(again.onPressed, isNotNull);
      expect(_count(adapter.calls, '/dashboard'), 1);
    });

    testWidgets('tek açık projede seçici atlanır; işlemden dönünce özet yenilenir', (tester) async {
      final owner = fixtureJson('owner');
      final adapter = await _pump(
        tester,
        user: ownerUser,
        script: {
          '/dashboard': [_ok(owner), _ok(owner)],
          '/notifications/unread-count': [
            _ok({'unread_count': 4}),
          ],
          '/dashboard/project-options': [
            _ok({
              'projects': [option('p1', 'Alfa Konut')],
            }),
          ],
        },
      );
      final action = find.widgetWithText(QuickActionButton, 'Satın Alma Talebi');
      await tester.ensureVisible(action);
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text('Proje seç'), findsNothing);
      expect(find.text('YENİ TALEP p1'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(_count(adapter.calls, '/dashboard'), 2);
      expect(adapter.calls, isNot(contains('/projects')));
    });
  });

  group('uygulamaya dönüş', () {
    Future<void> resume(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }

    testWidgets('az önce alınan veri yenilenmez (sunucu saati cihazla karşılaştırılmaz)', (tester) async {
      // Sunucu damgası cihaz saatine göre yıllar öncesini gösterse de (saat
      // kayması) yaş verinin CİHAZDA alındığı andan ölçülür.
      final json = fixtureJson('owner')..['generated_at'] = '2020-01-01T09:41:12+03:00';
      final adapter = await _pump(tester, user: ownerUser, script: _script(json));
      await resume(tester);
      expect(_count(adapter.calls, '/dashboard'), 1);
    });

    testWidgets('cihazda 5 dakikadan önce alınmış veri dönüşte yenilenir', (tester) async {
      final owner = fixtureJson('owner');
      final adapter = await _pump(
        tester,
        user: ownerUser,
        script: {
          '/dashboard': [_ok(owner), _ok(owner)],
          '/notifications/unread-count': [
            _ok({'unread_count': 4}),
            _ok({'unread_count': 4}),
          ],
        },
      );
      final container = ProviderScope.containerOf(tester.element(find.byType(DashboardScreen)));
      final data = container.read(dashboardProvider).requireValue;
      dashboardReceivedAt[data] = DateTime.now().subtract(const Duration(minutes: 6));
      await resume(tester);
      expect(_count(adapter.calls, '/dashboard'), 2);
    });
  });

  group('kurulum rehberi tercihi', () {
    testWidgets('"Gizle" kaydı okunurken rehber düzeni bir kare bile çizilmez', (tester) async {
      SharedPreferences.setMockInitialValues({
        'arvend.home.onboarding.hidden.${emptyOwnerUser.organizationId}.${emptyOwnerUser.id}': '1',
      });
      await _pump(tester, user: emptyOwnerUser, script: _script(fixtureJson('empty_company')), settle: false);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.text('Kurulum — ilk adımlar'), findsNothing, reason: '$i. kare');
      }
      await tester.pumpAndSettle();
      expect(find.text('Kurulum rehberi gizlendi'), findsOneWidget);
      expect(find.byType(KpiGrid), findsOneWidget);
    });
  });

  group('proje derin bağlantısı (?grup=&alt=)', () {
    Map<String, dynamic> project() => {
      'id': 'p1',
      'project_no': 'PRJ-001',
      'name': 'Merkez Ofis İnşaatı',
      'project_type': 'Konut',
      'customer_id': 'c1',
      'customer_name': 'Ali Veli',
      'customer_phone': '',
      'customer_email': '',
      'contract_amount': 100000,
      'currency': 'TRY',
      'status': 'active',
      'start_date': null,
      'end_date': null,
      'description': '',
      'created_at': '2026-09-01T00:00:00Z',
    };

    Future<FakeHttpClientAdapter> pumpProject(
      WidgetTester tester,
      String location, {
      Size size = const Size(400, 1600),
    }) async {
      final adapter = FakeHttpClientAdapter(
        script: {
          '/projects/p1': [_ok(project())],
          '/projects/p1/change-orders': [
            _ok({'change_orders': <dynamic>[]}),
          ],
          '/projects/p1/purchase-requests': [
            _ok({'purchase_requests': <dynamic>[]}),
          ],
          '/projects/p1/notes': [
            _ok({'notes': <dynamic>[]}),
          ],
          '/projects/p1/contract': [
            (status: 404, body: {'error': 'sözleşme bulunamadı'}),
          ],
          '/projects/p1/schedule': [
            _ok({'items': <dynamic>[]}),
          ],
          '/projects/p1/access': [
            _ok({'users': <dynamic>[]}),
          ],
        },
      );
      final client = await buildFakeApiClient(adapter);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final router = GoRouter(
        initialLocation: location,
        routes: [
          GoRoute(
            path: '/projeler/:id',
            builder: (_, s) => ProjectDetailScreen(
              projectId: s.pathParameters['id']!,
              initialGroup: s.uri.queryParameters['grup'],
              initialView: s.uri.queryParameters['alt'],
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(client),
            authControllerProvider.overrideWith(() => _FakeAuth(ownerUser)),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      return adapter;
    }

    /// Grubun alt görünüm çiplerinden seçili olanın `?alt=` değeri (gövde
    /// içindeki başka çipler -- ör. fatura filtresi -- sayılmaz).
    String selectedAlt(WidgetTester tester) {
      final selected = tester
          .widgetList<ChoiceChip>(find.byType(ChoiceChip))
          .where((c) => c.selected && c.key is ValueKey<String>)
          .map((c) => (c.key! as ValueKey<String>).value)
          .where((k) => k.startsWith('proje-alt-'))
          .toList();
      return selected.single.substring('proje-alt-'.length);
    }

    testWidgets('grup=finans&alt=ek-isler doğrudan Ek İşler görünümünü açar', (tester) async {
      final adapter = await pumpProject(tester, '/projeler/p1?grup=finans&alt=ek-isler');
      expect(selectedAlt(tester), 'ek-isler');
      expect(adapter.calls, contains('/projects/p1/change-orders'));
      // Özet sekmesi kurulmadı (ilk sekme atlandı).
      expect(find.text('Proje Alanları'), findsNothing);
    });

    testWidgets('grup=finans&alt=sozlesme Sözleşme görünümünü açar', (tester) async {
      final adapter = await pumpProject(tester, '/projeler/p1?grup=finans&alt=sozlesme');
      expect(selectedAlt(tester), 'sozlesme');
      expect(adapter.calls, contains('/projects/p1/contract'));
    });

    testWidgets('grup=operasyon&alt=satin-alma Satın Alma görünümünü açar', (tester) async {
      final adapter = await pumpProject(tester, '/projeler/p1?grup=operasyon&alt=satin-alma');
      expect(selectedAlt(tester), 'satin-alma');
      expect(adapter.calls, contains('/projects/p1/purchase-requests'));
    });

    testWidgets('grup=operasyon&alt=planlama Planlama görünümünü açar', (tester) async {
      final adapter = await pumpProject(tester, '/projeler/p1?grup=operasyon&alt=planlama');
      expect(selectedAlt(tester), 'planlama');
      expect(adapter.calls, contains('/projects/p1/schedule'));
    });

    testWidgets('grup=operasyon&alt=erisim son çipteki Erişim görünümünü açar ve çipi görünür alana kaydırır', (
      tester,
    ) async {
      final adapter = await pumpProject(tester, '/projeler/p1?grup=operasyon&alt=erisim', size: const Size(360, 800));
      expect(selectedAlt(tester), 'erisim');
      expect(adapter.calls, contains('/projects/p1/access'));
      final chip = tester.getRect(find.byKey(const ValueKey('proje-alt-erisim')));
      expect(chip.right, lessThanOrEqualTo(360));
      expect(chip.left, greaterThanOrEqualTo(0));
    });

    testWidgets('grup=dokumanlar&alt=notlar Notlar görünümünü açar', (tester) async {
      final adapter = await pumpProject(tester, '/projeler/p1?grup=dokumanlar&alt=notlar');
      expect(selectedAlt(tester), 'notlar');
      expect(adapter.calls, contains('/projects/p1/notes'));
    });

    testWidgets('bilinmeyen alt değeri grubun ilk görünümüne düşer', (tester) async {
      await pumpProject(tester, '/projeler/p1?grup=operasyon&alt=yok-boyle');
      expect(selectedAlt(tester), 'taseronlar');
    });
  });
}
