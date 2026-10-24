import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/app/app.dart';
import 'package:arvend/app/app_router.dart';
import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/subcontractors/presentation/subcontractor_portal_section.dart';

import '../../test_utils/fake_api_client.dart';
import '../contract_co/contract_co_test_support.dart' as cc;
import '../dashboard/fixtures.dart';
import '../projects/form_test_support.dart' show requestBodyFor;

/// Taşeron Paneli (backend migration 0075, docs/taseron-paneli.md):
/// taşeron hesabı yalnızca /taseron'a girer ve kendi işlerini görür; firma
/// taşeron kartından giriş açar, şifre sıfırlar, girişi kapatır ve proje
/// izni verir.

Map<String, dynamic> _portalMe() => {
      'id': 'tu1',
      'organization_id': 'org-1',
      'username': 'hasan.usta',
      'full_name': 'Hasan Usta',
      'role': 'kullanici',
      'is_active': true,
      'must_change_password': false,
      'onboarding_completed': true,
      'onboarding_step': 'completed',
      'organization_name': 'Deneme Yapı',
      'organization_role_code': 'subcontractor',
      'permissions': ['subcontractor.portal', 'notifications.read'],
      'supplier_id': 's1',
    };

Map<String, dynamic> _overview({bool empty = false}) => {
      'supplier': {'id': 's1', 'name': 'Elektrikçi Hasan'},
      'projects': empty
          ? <dynamic>[]
          : [
              {'id': 'p1', 'project_no': 'PRJ-2026-0007', 'name': 'Kadıköy Konut', 'status': 'active'},
            ],
      'engagements': empty
          ? <dynamic>[]
          : [
              {
                'kind': 'contract',
                'id': 'c1',
                'project_id': 'p1',
                'project_name': 'Kadıköy Konut',
                'project_no': 'PRJ-2026-0007',
                'title': 'Elektrik tesisatı',
                'status': 'active',
                'currency': 'TRY',
                'contract_amount': 200000,
                'certified': 80000,
                'paid': 50000,
                'payable': 26000,
                'retention': 4000,
                'advance_open': 0,
                'pending_claims': 15000,
                'remaining': 150000,
              },
            ],
      'payments': empty
          ? <dynamic>[]
          : [
              {
                'source': 'contract',
                'id': 'pay1',
                'project_id': 'p1',
                'project_name': 'Kadıköy Konut',
                'project_no': 'PRJ-2026-0007',
                'amount': 50000,
                'currency': 'TRY',
                'paid_date': '2026-10-10',
                'description': '1 nolu hakediş',
                'kind': 'work',
              },
              {
                'source': 'direct',
                'id': 'pay2',
                'project_id': null,
                'amount': 1500,
                'currency': 'TRY',
                'paid_date': '2026-10-14',
                'description': 'Depo tamiri',
                'kind': 'general',
              },
            ],
      'totals': empty
          ? <dynamic>[]
          : [
              {
                'currency': 'TRY',
                'contract_amount': 200000,
                'paid': 51500,
                'remaining': 150000,
                'payable': 26000,
                'retention': 4000,
              },
            ],
    };

Future<ProviderContainer> _pumpApp(WidgetTester tester, FakeHttpClientAdapter adapter) async {
  await tester.binding.setSurfaceSize(const Size(420, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final client = await buildFakeApiClient(adapter);
  final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const ArvendApp()));
  await tester.pumpAndSettle();
  return container;
}

final _owner = cc.buildUser(
  id: 'owner',
  role: UserRole.admin,
  roleCode: 'owner',
  permissions: const {'organization.suppliers.read', 'organization.users.read', 'organization.users.manage'},
);

Map<String, dynamic> _settings({bool active = true, bool granted = true}) => {
      'users': [
        {
          'id': 'tu1',
          'username': 'hasan.usta',
          'full_name': 'Hasan Usta',
          'is_active': active,
          'must_change_password': true,
          'last_login_at': null,
        },
      ],
      'projects': [
        {
          'id': 'p1',
          'project_no': 'PRJ-2026-0007',
          'name': 'Kadıköy Konut',
          'status': 'active',
          'granted': granted,
          'has_engagement': true,
        },
        {
          'id': 'p2',
          'project_no': 'PRJ-2026-0008',
          'name': 'Ataşehir Ofis',
          'status': 'active',
          'granted': false,
          'has_engagement': false,
        },
      ],
    };

Map<String, dynamic> _portalUser({bool active = true}) => {
      'id': 'tu1',
      'username': 'hasan.usta',
      'full_name': 'Hasan Usta',
      'is_active': active,
      'must_change_password': true,
    };

Future<FakeHttpClientAdapter> _pumpSection(
  WidgetTester tester, {
  required User user,
  required Map<String, List<ScriptedResponse>> script,
  bool cardActive = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final adapter = FakeHttpClientAdapter(script: script);
  final client = await buildFakeApiClient(adapter);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => cc.FakeAuth(user)),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('tr', 'TR'),
        supportedLocales: const [Locale('tr', 'TR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SubcontractorPortalSection(
              supplierId: 's1',
              suggestedName: 'Hasan Çelik',
              cardActive: cardActive,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return adapter;
}

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  group('taşeron hesabı', () {
    testWidgets('girişte Taşeron Paneli açılır; firma ekranlarının hiçbir ucu çağrılmaz', (tester) async {
      // /dashboard, /offers/, /notifications/unread-count KASITLI OLARAK
      // script'te yok: çağrılırsa adaptör StateError fırlatır.
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _portalMe())],
        '/portal/overview': [(status: 200, body: _overview())],
      });
      await _pumpApp(tester, adapter);

      expect(find.text('Elektrikçi Hasan'), findsOneWidget);
      expect(find.text('Merhaba, Hasan Usta'), findsOneWidget);
      expect(find.text('Dikkat Gerektirenler'), findsNothing);
      expect(adapter.calls, ['/auth/me', '/portal/overview']);
    });

    testWidgets('kalan alacak, işler ve ödemeler (proje dışı dahil) görünür', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _portalMe())],
        '/portal/overview': [(status: 200, body: _overview())],
      });
      await _pumpApp(tester, adapter);

      final totals = find.byKey(const ValueKey('portal-toplam-TRY'));
      expect(totals, findsOneWidget);
      expect(find.descendant(of: totals, matching: find.textContaining('150.000')), findsOneWidget);
      expect(find.descendant(of: totals, matching: find.textContaining('51.500')), findsOneWidget);

      final work = find.byKey(const ValueKey('portal-is-c1'));
      expect(work, findsOneWidget);
      expect(find.descendant(of: work, matching: find.text('Onaylı hakediş')), findsOneWidget);
      expect(find.descendant(of: work, matching: find.text('Onay bekleyen hakediş')), findsOneWidget);
      expect(find.text('PRJ-2026-0007 · Kadıköy Konut'), findsOneWidget);

      expect(find.byKey(const ValueKey('portal-odeme-pay1')), findsOneWidget);
      expect(find.textContaining('Proje dışı'), findsOneWidget);
      expect(find.byKey(const ValueKey('portal-izin-yok')), findsNothing);
    });

    testWidgets('proje izni yoksa bunu söyleyen kart görünür', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _portalMe())],
        '/portal/overview': [(status: 200, body: _overview(empty: true))],
      });
      await _pumpApp(tester, adapter);

      expect(find.byKey(const ValueKey('portal-izin-yok')), findsOneWidget);
      expect(find.textContaining('Deneme Yapı size henüz bir proje açmadı'), findsOneWidget);
    });

    testWidgets('firma sayfasına gitmeye çalışınca panele geri döner', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _portalMe())],
        '/portal/overview': [
          (status: 200, body: _overview()),
          (status: 200, body: _overview()),
        ],
      });
      final container = await _pumpApp(tester, adapter);

      container.read(routerProvider).go('/diger/taseronlar');
      await tester.pumpAndSettle();
      expect(container.read(routerProvider).routerDelegate.currentConfiguration.uri.path, '/taseron');
      expect(adapter.calls.where((c) => !c.startsWith('/portal') && c != '/auth/me'), isEmpty);
    });

    testWidgets('profil açılır (şifre değiştirme ve çıkış için)', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/auth/me': [(status: 200, body: _portalMe())],
        '/portal/overview': [(status: 200, body: _overview())],
      });
      await _pumpApp(tester, adapter);

      await tester.tap(find.byKey(const ValueKey('portal-profil')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, 'Çıkış Yap'), findsOneWidget);
    });
  });

  testWidgets('firma kullanıcısı /taseron adresinde kalamaz, ana sayfaya döner', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/auth/me': [
        (
          status: 200,
          body: {
            ..._portalMe(),
            'id': 'u1',
            'role': 'admin',
            'organization_role_code': 'owner',
            'permissions': <String>[],
            'supplier_id': null,
          },
        ),
      ],
      '/dashboard': [
        (status: 200, body: fixtureJson('owner')),
        (status: 200, body: fixtureJson('owner')),
      ],
      '/offers/': [
        (status: 200, body: {'offers': <dynamic>[], 'total': 0}),
        (status: 200, body: {'offers': <dynamic>[], 'total': 0}),
      ],
      '/notifications/unread-count': [
        (status: 200, body: {'unread_count': 0}),
        (status: 200, body: {'unread_count': 0}),
      ],
    });
    final container = await _pumpApp(tester, adapter);
    expect(find.text('Dikkat Gerektirenler'), findsOneWidget);

    container.read(routerProvider).go('/taseron');
    await tester.pumpAndSettle();
    expect(container.read(routerProvider).routerDelegate.currentConfiguration.uri.path, '/ana-sayfa');
    expect(adapter.calls, isNot(contains('/portal/overview')));
  });

  group('taşeron kartındaki Taşeron Paneli bölümü', () {
    testWidgets('kullanıcı okuma izni olmayana hiç görünmez, istek atılmaz', (tester) async {
      final pm = cc.buildUser(
        id: 'pm',
        roleCode: 'project_manager',
        permissions: const {'organization.suppliers.read'},
      );
      final adapter = await _pumpSection(tester, user: pm, script: {});
      expect(find.byKey(const ValueKey('taseron-paneli')), findsNothing);
      expect(adapter.calls, isEmpty);
    });

    testWidgets('girişleri ve proje izinlerini gösterir; yönetemeyen düğme görmez', (tester) async {
      final reader = cc.buildUser(
        id: 'rd',
        role: UserRole.admin,
        roleCode: 'admin',
        permissions: const {'organization.suppliers.read', 'organization.users.read'},
      );
      await _pumpSection(tester, user: reader, script: {
        '/subcontractors/s1/portal': [(status: 200, body: _settings())],
      });
      expect(find.byKey(const ValueKey('portal-kullanici-tu1')), findsOneWidget);
      expect(find.textContaining('İlk girişi bekleniyor'), findsOneWidget);
      expect(find.text('PRJ-2026-0007 · Kadıköy Konut'), findsOneWidget);
      expect(find.byKey(const ValueKey('portal-giris-ac')), findsNothing);
      expect(find.byKey(const ValueKey('portal-izin-duzenle')), findsNothing);
      expect(find.byKey(const ValueKey('portal-kullanici-menu-tu1')), findsNothing);
    });

    testWidgets('arşivdeki karta giriş açılamaz', (tester) async {
      await _pumpSection(tester, user: _owner, cardActive: false, script: {
        '/subcontractors/s1/portal': [(status: 200, body: _settings())],
      });
      expect(find.byKey(const ValueKey('portal-giris-ac')), findsNothing);
    });

    testWidgets('"Giriş aç" geçici şifreyle hesap açar ve bilgileri bir kez gösterir', (tester) async {
      final adapter = await _pumpSection(tester, user: _owner, script: {
        '/subcontractors/s1/portal': [
          (status: 200, body: {..._settings(), 'users': <dynamic>[]}),
          (status: 200, body: _settings()),
        ],
        '/subcontractors/s1/portal/users': [(status: 201, body: {..._portalUser(), 'username': 'hasan.celik'})],
      });
      expect(find.text('Henüz giriş açılmadı.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('portal-giris-ac')));
      await tester.pumpAndSettle();
      // Ad karttan, kullanıcı adı addan önerilir; şifre üretilmiştir.
      expect(find.widgetWithText(TextFormField, 'Hasan Çelik'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'hasan.celik'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('portal-giris-kaydet')));
      await tester.pumpAndSettle();

      final body = requestBodyFor(adapter, '/subcontractors/s1/portal/users');
      expect(body['full_name'], 'Hasan Çelik');
      expect(body['username'], 'hasan.celik');
      final password = body['temporary_password'] as String;
      expect(password.length, 10);

      expect(find.text('Giriş bilgileri'), findsOneWidget);
      expect(find.text('Kullanıcı adı: hasan.celik'), findsOneWidget);
      expect(find.text('Geçici şifre: $password'), findsOneWidget);
      await tester.tap(find.text('Tamam'));
      await tester.pumpAndSettle();

      expect(find.text('Giriş bilgileri'), findsNothing);
      expect(find.byKey(const ValueKey('portal-kullanici-tu1')), findsOneWidget);
      expect(adapter.calls.where((c) => c == '/subcontractors/s1/portal').length, 2);
    });

    testWidgets('alınmış kullanıcı adı formda hata olarak görünür', (tester) async {
      await _pumpSection(tester, user: _owner, script: {
        '/subcontractors/s1/portal': [(status: 200, body: {..._settings(), 'users': <dynamic>[]})],
        '/subcontractors/s1/portal/users': [
          (status: 409, body: {'error': 'bu kullanıcı adı zaten kullanılıyor'}),
        ],
      });
      await tester.tap(find.byKey(const ValueKey('portal-giris-ac')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('portal-giris-kaydet')));
      await tester.pumpAndSettle();

      expect(find.text('bu kullanıcı adı zaten kullanılıyor'), findsOneWidget);
      expect(find.text('Giriş bilgileri'), findsNothing);
    });

    testWidgets('"Şifreyi sıfırla" yeni geçici şifre gönderir ve gösterir', (tester) async {
      final adapter = await _pumpSection(tester, user: _owner, script: {
        '/subcontractors/s1/portal': [
          (status: 200, body: _settings()),
          (status: 200, body: _settings()),
        ],
        '/subcontractors/s1/portal/users/tu1/password': [(status: 200, body: _portalUser())],
      });
      await tester.tap(find.byKey(const ValueKey('portal-kullanici-menu-tu1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Şifreyi sıfırla').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sıfırla'));
      await tester.pumpAndSettle();

      final password = requestBodyFor(adapter, '/subcontractors/s1/portal/users/tu1/password')['temporary_password'];
      expect((password as String).length, 10);
      expect(find.text('Geçici şifre: $password'), findsOneWidget);
    });

    testWidgets('"Girişi kapat" hesabı kapatır', (tester) async {
      final adapter = await _pumpSection(tester, user: _owner, script: {
        '/subcontractors/s1/portal': [
          (status: 200, body: _settings()),
          (status: 200, body: _settings(active: false)),
        ],
        '/subcontractors/s1/portal/users/tu1/active': [(status: 200, body: _portalUser(active: false))],
      });
      await tester.tap(find.byKey(const ValueKey('portal-kullanici-menu-tu1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Girişi kapat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kapat'));
      await tester.pumpAndSettle();

      expect(requestBodyFor(adapter, '/subcontractors/s1/portal/users/tu1/active'), {'active': false});
      expect(find.textContaining('Giriş kapalı'), findsOneWidget);
    });

    testWidgets('"İzinleri düzenle" seçilen projeleri kaydeder', (tester) async {
      final adapter = await _pumpSection(tester, user: _owner, script: {
        '/subcontractors/s1/portal': [
          (status: 200, body: _settings()),
          (status: 200, body: _settings()),
        ],
        '/subcontractors/s1/portal/projects': [(status: 200, body: _settings())],
      });
      await tester.tap(find.byKey(const ValueKey('portal-izin-duzenle')));
      await tester.pumpAndSettle();
      expect(find.text('Bu projede işi var'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('portal-izin-p1')));
      await tester.tap(find.byKey(const ValueKey('portal-izin-p2')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('portal-izin-kaydet')));
      await tester.pumpAndSettle();

      expect(requestBodyFor(adapter, '/subcontractors/s1/portal/projects'), {
        'project_ids': ['p2'],
      });
      expect(adapter.methods[adapter.calls.indexOf('/subcontractors/s1/portal/projects')], 'PUT');
      expect(find.text('Proje izinleri kaydedildi.'), findsOneWidget);
    });
  });

  group('yardımcılar', () {
    test('geçici şifre 10 karakter ve karışan harf içermez', () {
      for (var i = 0; i < 50; i++) {
        final p = generateTemporaryPassword();
        expect(p.length, 10);
        expect(p, isNot(matches(RegExp('[0O1lI]'))));
      }
    });

    test('kullanıcı adı önerisi Türkçe harfleri sadeleştirir', () {
      expect(suggestPortalUsername('Hasan Çelik'), 'hasan.celik');
      expect(suggestPortalUsername('  Şükrü Öztürk Ltd. Şti. '), 'sukru.ozturk.ltd.sti');
      expect(suggestPortalUsername('İsmail Ağa'), 'ismail.aga');
    });
  });
}
