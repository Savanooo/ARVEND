import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/app/app_router.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/profile/presentation/other_menu_screen.dart';

import '../dashboard/fixtures.dart';

/// Diğer menüsünün "Yönetim" bölümü: web /admin/** modüllerinin mobil
/// girişleri KATI `canAccess` ile süzülür; her girişin rotası gerçek
/// yönlendiricide kendi ekranına eşleşir.
class _FakeAuth extends AuthController {
  _FakeAuth(this._user);
  final User? _user;

  @override
  Future<User?> build() async => _user;
}

User _custom({required UserRole role, required Iterable<String> permissions}) => User(
  id: 'u-custom',
  organizationId: 'org-1',
  username: 'ozel',
  fullName: 'Özel Kullanıcı',
  role: role,
  isActive: true,
  mustChangePassword: false,
  onboardingCompleted: true,
  onboardingStep: 'completed',
  organizationName: 'Arvend Yapı',
  permissions: permissions.toSet(),
);

// Katalog -> Ekip -> Ayarlar alt başlıkları sırasıyla. Zam Geçmişi ve Fiyat
// Kaynakları menüde ayrı öğe değil (Ürünler ekranından açılır).
const _managementOrder = [
  'Ürünler',
  'Tedarikçiler',
  'Maliyet Kodları',
  'Metraj Reçeteleri',
  'Personel',
  'Kullanıcılar',
  'Roller & Yetkiler',
  'Firma Ayarları',
  'E-posta Ayarları',
];

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

/// AppBar başlığı test motorunda kutu glifine düşmesin diye Inter verilir
/// (dashboard golden testleriyle aynı düzeltme).
ThemeData _theme() {
  final theme = AppTheme.light();
  return theme.copyWith(
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Inter'),
    ),
  );
}

Widget _harness(User? user) => ProviderScope(
  overrides: [authControllerProvider.overrideWith(() => _FakeAuth(user))],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _theme(),
    locale: const Locale('tr', 'TR'),
    supportedLocales: const [Locale('tr', 'TR')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: const OtherMenuScreen(),
  ),
);

/// Ekranda (kaydırma dahil) çizilen menü etiketleri, yukarıdan aşağıya.
List<String> _labelsInOrder(WidgetTester tester, Iterable<String> candidates) {
  final found = <(double, String)>[];
  for (final label in candidates) {
    final finder = find.text(label, skipOffstage: false);
    if (finder.evaluate().isNotEmpty) found.add((tester.getTopLeft(finder.first).dy, label));
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final f in found) f.$2];
}

Future<void> _pumpTall(WidgetTester tester, User? user) async {
  // Uzun menü tek görünümde: kaydırmadan tüm öğeler çizilsin.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(360, 2000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_harness(user));
  await tester.pumpAndSettle();
}

void main() {
  group('Diğer > Yönetim görünürlüğü', () {
    testWidgets('Sahip (admin + tüm izinler) tüm yönetim girişlerini sırayla görür', (tester) async {
      await _pumpTall(tester, ownerUser);
      expect(find.text('Yönetim'), findsOneWidget);
      expect(_labelsInOrder(tester, _managementOrder), _managementOrder);
      // Bölüm sırası: İş Araçları -> Yönetim (Katalog/Ekip/Ayarlar) -> Hesap;
      // hesap öğeleri en sonda.
      expect(
        _labelsInOrder(tester, ['İş Araçları', 'Yönetim', 'KATALOG', 'EKİP', 'AYARLAR', 'Hesap', 'Profil']),
        ['İş Araçları', 'Yönetim', 'KATALOG', 'EKİP', 'AYARLAR', 'Hesap', 'Profil'],
      );
      expect(_labelsInOrder(tester, ['Metraj Reçeteleri', 'Personel', 'Firma Ayarları', 'Profil']).last, 'Profil');
      expect(find.text('Zam Geçmişi'), findsNothing);
      expect(find.text('Fiyat Kaynakları'), findsNothing);
      // Mevcut girişler yerinde.
      for (final label in ['Müşteriler', 'Metraj Hesaplama', 'Mesai', 'Profil', 'Bildirimler', 'Hakkında']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('kaba rol admin değilse Kullanıcılar/Roller/E-posta/Firma Ayarları gizli (tüm izinler olsa da)',
        (tester) async {
      await _pumpTall(tester, _custom(role: UserRole.kullanici, permissions: kAllPermissions));
      expect(_labelsInOrder(tester, _managementOrder), [
        'Ürünler',
        'Tedarikçiler',
        'Maliyet Kodları',
        'Metraj Reçeteleri',
        'Personel',
      ]);
      // Ayarlar alt başlığı boşsa hiç çizilmez.
      expect(find.text('AYARLAR'), findsNothing);
    });

    testWidgets('Finans rolü yalnızca Tedarikçiler ve Maliyet Kodları görür', (tester) async {
      await _pumpTall(tester, financeUser);
      expect(_labelsInOrder(tester, _managementOrder), ['Tedarikçiler', 'Maliyet Kodları']);
    });

    testWidgets('Saha rolünde Yönetim bölümü hiç yok', (tester) async {
      await _pumpTall(tester, fieldUser);
      expect(find.text('Yönetim'), findsNothing);
      expect(_labelsInOrder(tester, _managementOrder), isEmpty);
      expect(find.text('Mesai'), findsOneWidget);
    });

    testWidgets('izin kümesi boşsa (eski oturum) yönetim ekranları gizli -- fail-closed', (tester) async {
      await _pumpTall(tester, _custom(role: UserRole.admin, permissions: const []));
      // İş Araçları eskisi gibi fail-open; Firma Ayarları kaba role bakar.
      expect(find.text('Müşteriler'), findsOneWidget);
      expect(_labelsInOrder(tester, _managementOrder), ['Firma Ayarları']);
    });

    testWidgets('kullanıcı yüklenmemişse (null) yönetim girişi yok', (tester) async {
      await _pumpTall(tester, null);
      expect(find.text('Yönetim'), findsNothing);
      expect(find.text('Hakkında'), findsOneWidget);
    });

    testWidgets('kişiye özel yalnızca products.read verilmiş üye Ürünler grubunu görür', (tester) async {
      await _pumpTall(tester, _custom(role: UserRole.kullanici, permissions: const ['products.read']));
      expect(_labelsInOrder(tester, _managementOrder), ['Ürünler']);
      expect(find.text('KATALOG'), findsOneWidget);
      expect(find.text('EKİP'), findsNothing);
    });
  });

  test('her yönetim girişi gerçek yönlendiricide kendi ekranına eşleşir (":id" yutmaz)', () {
    final container = ProviderContainer(overrides: [authControllerProvider.overrideWith(() => _FakeAuth(ownerUser))]);
    addTearDown(container.dispose);
    final configuration = container.read(routerProvider).configuration;
    final entries = [...kManagementMenuEntries, ...kManagementSettingsEntries];
    expect(entries.map((e) => e.label), [
      for (final l in _managementOrder)
        if (l != 'Firma Ayarları') l,
    ]);
    for (final e in entries) {
      final match = configuration.findMatch(Uri.parse(e.route));
      expect(match.isError, isFalse, reason: e.route);
      expect(match.fullPath, e.route, reason: '${e.label} başka bir rotaya düştü: ${match.fullPath}');
    }
    // Diğer yeni rotalar (form/detay/alt ekranlar).
    const nested = <String, String>{
      '/diger/urunler/yeni': '/diger/urunler/yeni',
      '/diger/urunler/p1/duzenle': '/diger/urunler/:id/duzenle',
      '/diger/personel/e1': '/diger/personel/:id',
      '/diger/personel/e1/duzenle': '/diger/personel/:id/duzenle',
      '/diger/personel/e1/giris-hesabi': '/diger/personel/:id/giris-hesabi',
      '/diger/roller/r1': '/diger/roller/:id',
      '/diger/tedarikciler/s1': '/diger/tedarikciler/:id',
      '/diger/maliyet-kodlari/c1': '/diger/maliyet-kodlari/:id',
      '/diger/metraj-receteleri/g1': '/diger/metraj-receteleri/:groupId',
      '/diger/metraj-receteleri/g1/k1': '/diger/metraj-receteleri/:groupId/:categoryId',
      '/diger/metraj': '/diger/metraj',
      '/projeler/p1/duzenle': '/projeler/:id/duzenle',
    };
    nested.forEach((location, template) {
      final match = configuration.findMatch(Uri.parse(location));
      expect(match.isError, isFalse, reason: location);
      expect(match.fullPath, template, reason: location);
    });
  });

  group('goldens', () {
    setUpAll(_loadAppFonts);

    Future<void> shoot(WidgetTester tester, User user, String name, {bool full = false}) async {
      tester.view.devicePixelRatio = 2.0;
      tester.view.physicalSize = const Size(360, 800) * 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_harness(user));
      await tester.pumpAndSettle();
      if (full) {
        final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
        final height = (800 + scrollable.position.maxScrollExtent).ceilToDouble();
        tester.view.physicalSize = Size(360, height) * 2.0;
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    }

    testWidgets('owner 360x800', (tester) => shoot(tester, ownerUser, 'other_menu_owner_360x800'));
    testWidgets('owner 360 full', (tester) => shoot(tester, ownerUser, 'other_menu_owner_360_full', full: true));
    testWidgets('finance 360x800', (tester) => shoot(tester, financeUser, 'other_menu_finance_360x800'));
    testWidgets('field 360x800', (tester) => shoot(tester, fieldUser, 'other_menu_field_360x800'));
  });
}
