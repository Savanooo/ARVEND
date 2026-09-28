import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/suppliers/presentation/widgets/supplier_ui.dart';
import 'package:arvend/features/suppliers/suppliers_routes.dart';

import 'suppliers_test_support.dart';

/// Uzun detay/form ekranları kaydırmadan test edilebilsin diye yüksek bir
/// yüzey (mantıksal 480x1800).
void _tallSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(480, 1800);
  addTearDown(tester.view.reset);
}

Future<void> _pumpApp(
  WidgetTester tester, {
  required User user,
  required FakeSuppliersRepository repo,
  String location = kSuppliersPath,
}) async {
  _tallSurface(tester);
  await tester.pumpWidget(buildSuppliersApp(user: user, repo: repo, initialLocation: location));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  group('list', () {
    testWidgets('owner sees active suppliers, counts on chips and the create button', (tester) async {
      final repo = FakeSuppliersRepository();
      await _pumpApp(tester, user: ownerUser, repo: repo);

      expect(find.text('Kaya Yapı Malzemeleri Sanayi ve Ticaret A.Ş.'), findsOneWidget);
      expect(find.text('Demir Profil Çelik Ltd. Şti.'), findsOneWidget);
      expect(find.text('Öztürk Hafriyat Nakliyat'), findsOneWidget);
      // Arşivlenmiş varsayılan olarak gizli (web: "arşivlenmişleri de göster" kapalı).
      expect(find.text('Işık Boya Kimya San. Tic. Ltd. Şti.'), findsNothing);
      expect(find.text('Aktif (4)'), findsOneWidget);
      expect(find.text('Arşiv (1)'), findsOneWidget);
      expect(find.text('Tümü (5)'), findsOneWidget);
      expect(find.text('4 tedarikçi'), findsOneWidget);
      expect(find.text('Yeni Tedarikçi'), findsOneWidget);
      expect(find.text(kSuppliersReadOnlyText), findsNothing);
      expect(repo.calls, ['list']);
    });

    testWidgets('filter chips switch between active, archived and all', (tester) async {
      await _pumpApp(tester, user: ownerUser, repo: FakeSuppliersRepository());

      await tester.tap(find.text('Arşiv (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Işık Boya Kimya San. Tic. Ltd. Şti.'), findsOneWidget);
      expect(find.text('Arşivlendi'), findsOneWidget);
      expect(find.text('Demir Profil Çelik Ltd. Şti.'), findsNothing);

      // Test yazı tipi (Ahem) geniş çizer; üçüncü çip yatay kaydırmayla görünür.
      await tester.ensureVisible(find.text('Tümü (5)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tümü (5)'));
      await tester.pumpAndSettle();
      expect(find.text('5 tedarikçi'), findsOneWidget);
    });

    testWidgets('search narrows by code / legal / trade name with Turkish folding and can be cleared',
        (tester) async {
      await _pumpApp(tester, user: ownerUser, repo: FakeSuppliersRepository());

      await tester.enterText(find.byType(TextField), 'ege');
      await tester.pumpAndSettle();
      expect(find.text('Ege Elektrik Taahhüt Hizmetleri'), findsOneWidget);
      expect(find.text('Demir Profil Çelik Ltd. Şti.'), findsNothing);
      expect(find.text('1 sonuç'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'ÖZTÜRK');
      await tester.pumpAndSettle();
      expect(find.text('Öztürk Hafriyat Nakliyat'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'yok-böyle-bir-şey');
      await tester.pumpAndSettle();
      expect(find.text('Arama kriterlerine uyan tedarikçi yok.'), findsOneWidget);

      await tester.tap(find.byTooltip('Aramayı temizle'));
      await tester.pumpAndSettle();
      expect(find.text('4 tedarikçi'), findsOneWidget);
    });

    testWidgets('read-only user: notice, no create button, rows still open the detail', (tester) async {
      await _pumpApp(tester, user: readOnlyUser, repo: FakeSuppliersRepository());

      expect(find.text(kSuppliersReadOnlyText), findsOneWidget);
      expect(find.text('Yeni Tedarikçi'), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);

      await tester.tap(find.text('Demir Profil Çelik Ltd. Şti.'));
      await tester.pumpAndSettle();
      expect(find.text('Firma Bilgileri'), findsOneWidget);
    });

    testWidgets('non-admin with suppliers.manage gets the create button (no requireAdmin)', (tester) async {
      await _pumpApp(tester, user: managerUser, repo: FakeSuppliersRepository());
      expect(find.text('Yeni Tedarikçi'), findsOneWidget);
    });

    for (final (name, user) in [('no supplier permission', noAccessUser), ('empty permission set', emptyPermissionsUser)]) {
      testWidgets('$name: lock message and the API is never called', (tester) async {
        final repo = FakeSuppliersRepository();
        await _pumpApp(tester, user: user, repo: repo);
        expect(find.text(kSuppliersNoAccessText), findsOneWidget);
        expect(find.byIcon(Icons.lock_outline), findsOneWidget);
        expect(repo.calls, isEmpty);
      });
    }

    testWidgets('server 403 on the list shows the no-access message instead of crashing', (tester) async {
      final repo = FakeSuppliersRepository()..listError = forbidden;
      await _pumpApp(tester, user: ownerUser, repo: repo);
      expect(tester.takeException(), isNull);
      expect(find.text(kSuppliersNoAccessText), findsOneWidget);
    });

    testWidgets('other errors show the message with a working retry', (tester) async {
      final repo = FakeSuppliersRepository()
        ..listError = const ApiException(statusCode: 500, message: 'Sunucu hatası', kind: ApiErrorKind.server);
      await _pumpApp(tester, user: ownerUser, repo: repo);
      expect(find.text('Sunucu hatası'), findsOneWidget);

      repo.listError = null;
      await tester.tap(find.text('Tekrar Dene'));
      await tester.pumpAndSettle();
      expect(find.text('Kaya Yapı Malzemeleri Sanayi ve Ticaret A.Ş.'), findsOneWidget);
      expect(repo.calls, ['list', 'list']);
    });

    testWidgets('empty catalog explains what suppliers are for', (tester) async {
      await _pumpApp(tester, user: ownerUser, repo: FakeSuppliersRepository(const []));
      expect(
        find.text('Henüz hiç tedarikçi oluşturulmamış. Satın alma talepleri/RFQ/siparişler bu kataloktan seçilir.'),
        findsOneWidget,
      );
    });

    testWidgets('pull-to-refresh reloads the list', (tester) async {
      final repo = FakeSuppliersRepository();
      await _pumpApp(tester, user: ownerUser, repo: repo);
      // Eşik, görünüm yüksekliğinin %25'i -- yüksek test yüzeyinde uzun sürükleme.
      await tester.fling(find.text('Demir Profil Çelik Ltd. Şti.'), const Offset(0, 800), 1000);
      await tester.pumpAndSettle();
      expect(repo.calls, ['list', 'list']);
    });
  });

  group('detail', () {
    testWidgets('shows every field, IBAN status (never the IBAN) and manage actions for the owner', (tester) async {
      final repo = FakeSuppliersRepository();
      await _pumpApp(tester, user: ownerUser, repo: repo, location: supplierDetailPath('s1'));

      for (final text in [
        'TED-001',
        'Kaya Yapı',
        'Kaba yapı malzemeleri',
        '5840123456',
        'Kozyatağı',
        'Ahmet Kaya',
        '0216 555 10 20',
        'satis@kayayapi.com.tr',
        'İstanbul',
        'Türkiye',
        'Esenşehir Mah. Sanayi Cad. No:12 Ümraniye',
        'Çimento ve agrega ana tedarikçisi. Ödeme vadesi 30 gün.',
        'IBAN kayıtlı',
        'Oluşturulma: 12.09.2026 · Son güncelleme: 27.09.2026',
      ]) {
        expect(find.text(text), findsWidgets, reason: text);
      }
      expect(find.text('Aktif'), findsOneWidget);
      expect(find.byTooltip('Düzenle'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Arşivle'), findsOneWidget);
      // Detay, listenin çocuk rotası: derin bağlantıda liste de altta kurulur.
      expect(repo.calls, containsAll(['get:s1']));
      expect(repo.calls.where((c) => c.startsWith('get:')), ['get:s1']);
    });

    testWidgets('empty fields render as a dash and "IBAN kayıtlı değil"', (tester) async {
      await _pumpApp(tester, user: ownerUser, repo: FakeSuppliersRepository(), location: supplierDetailPath('s2'));
      expect(find.text('IBAN kayıtlı değil'), findsOneWidget);
      expect(find.text('—'), findsWidgets);
      expect(find.text('Not yok.'), findsOneWidget);
    });

    testWidgets('read-only user: notice and no edit/archive controls', (tester) async {
      await _pumpApp(tester, user: readOnlyUser, repo: FakeSuppliersRepository(), location: supplierDetailPath('s1'));
      expect(find.text(kSuppliersReadOnlyText), findsOneWidget);
      expect(find.byTooltip('Düzenle'), findsNothing);
      expect(find.text('Arşivle'), findsNothing);
      expect(find.text('Etkinleştir'), findsNothing);
    });

    testWidgets('no permission on a deep link: lock message, no request', (tester) async {
      final repo = FakeSuppliersRepository();
      await _pumpApp(tester, user: noAccessUser, repo: repo, location: supplierDetailPath('s1'));
      expect(find.text(kSuppliersNoAccessText), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('unknown id shows the backend not-found message', (tester) async {
      await _pumpApp(tester, user: ownerUser, repo: FakeSuppliersRepository(), location: supplierDetailPath('zzz'));
      expect(find.text('tedarikçi bulunamadı'), findsOneWidget);
    });

    testWidgets('archive asks for confirmation; cancel does nothing, confirm archives', (tester) async {
      final repo = FakeSuppliersRepository();
      await _pumpApp(tester, user: ownerUser, repo: repo, location: supplierDetailPath('s1'));

      await tester.tap(find.widgetWithText(OutlinedButton, 'Arşivle'));
      await tester.pumpAndSettle();
      expect(find.text('Tedarikçiyi Arşivle'), findsOneWidget);
      expect(find.textContaining('yeni PR/RFQ/PO\'larda seçilemeyecek'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Vazgeç'));
      await tester.pumpAndSettle();
      expect(repo.calls.where((c) => c.startsWith('archive')), isEmpty);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Arşivle'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Arşivle'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('archive:s1'));
      expect(find.text('Tedarikçi arşivlendi.'), findsOneWidget);
      expect(find.text('Arşivlendi'), findsWidgets);
      expect(find.widgetWithText(OutlinedButton, 'Etkinleştir'), findsOneWidget);
    });

    testWidgets('reactivate an archived supplier', (tester) async {
      final repo = FakeSuppliersRepository();
      await _pumpApp(tester, user: ownerUser, repo: repo, location: supplierDetailPath('s4'));

      await tester.tap(find.widgetWithText(OutlinedButton, 'Etkinleştir'));
      await tester.pumpAndSettle();
      expect(find.text('Tedarikçiyi Etkinleştir'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Etkinleştir'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('reactivate:s4'));
      expect(find.text('Tedarikçi yeniden etkinleştirildi.'), findsOneWidget);
    });

    testWidgets('a 403 on archive becomes a clear message, not a crash', (tester) async {
      final repo = FakeSuppliersRepository()..writeError = forbidden;
      await _pumpApp(tester, user: ownerUser, repo: repo, location: supplierDetailPath('s1'));

      await tester.tap(find.widgetWithText(OutlinedButton, 'Arşivle'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Arşivle'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Bu işlem için yetkin yok.'), findsOneWidget);
      expect(find.text('Aktif'), findsOneWidget);
    });
  });

  group('form', () {
    testWidgets('create validates required fields, email and IBAN, then posts a normalized IBAN', (tester) async {
      final repo = FakeSuppliersRepository();
      await _pumpApp(tester, user: ownerUser, repo: repo);

      await tester.tap(find.text('Yeni Tedarikçi'));
      await tester.pumpAndSettle();
      expect(find.text('Yeni Tedarikçi'), findsWidgets);

      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Tedarikçi kodu zorunludur'), findsOneWidget);
      expect(find.text('Unvan zorunludur'), findsOneWidget);
      expect(repo.calls.where((c) => c == 'create'), isEmpty);

      await tester.enterText(find.byKey(const ValueKey('supplier-code')), 'TED-010');
      await tester.enterText(find.byKey(const ValueKey('supplier-legal-name')), 'Anadolu Hırdavat Ltd. Şti.');
      await tester.enterText(find.byKey(const ValueKey('supplier-email')), 'gecersiz');
      await tester.enterText(find.byKey(const ValueKey('supplier-iban')), 'TR34 0006 1005 1978 6457 8413 26');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Geçerli bir e-posta adresi gir'), findsOneWidget);
      expect(find.textContaining('Geçerli bir IBAN gir'), findsOneWidget);
      expect(repo.created, isEmpty);

      await tester.enterText(find.byKey(const ValueKey('supplier-email')), 'info@anadolu.com');
      await tester.enterText(find.byKey(const ValueKey('supplier-iban')), 'tr33 0006 1005 1978 6457 8413 26');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();

      final input = repo.created.single;
      expect(input.code, 'TED-010');
      expect(input.legalName, 'Anadolu Hırdavat Ltd. Şti.');
      expect(input.email, 'info@anadolu.com');
      expect(input.country, 'Türkiye');
      expect(input.iban, 'TR330006100519786457841326');
      expect(find.text('"Anadolu Hırdavat Ltd. Şti." eklendi.'), findsOneWidget);
      // Liste yenilendi, yeni kayıt görünüyor.
      expect(find.text('Anadolu Hırdavat Ltd. Şti.'), findsOneWidget);
    });

    testWidgets('edit: code locked, IBAN left empty is not sent, other fields (incl. specialty) round-trip',
        (tester) async {
      final repo = FakeSuppliersRepository();
      await _pumpApp(tester, user: ownerUser, repo: repo, location: supplierDetailPath('s1'));

      await tester.tap(find.byTooltip('Düzenle'));
      await tester.pumpAndSettle();
      expect(find.text('Tedarikçiyi Düzenle'), findsOneWidget);
      final codeField = tester.widget<TextField>(
        find.descendant(of: find.byKey(const ValueKey('supplier-code')), matching: find.byType(TextField)),
      );
      expect(codeField.enabled, isFalse);
      expect(find.textContaining('Kod oluşturulduktan sonra değiştirilemez'), findsOneWidget);
      expect(find.text('IBAN (değiştirmek için doldur)'), findsOneWidget);
      expect(find.text('Şu an kayıtlı bir IBAN var.'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('supplier-legal-name')), 'Kaya Yapı A.Ş.');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();

      final (id, input) = repo.updated.single;
      expect(id, 's1');
      expect(input.code, 'TED-001');
      expect(input.legalName, 'Kaya Yapı A.Ş.');
      expect(input.iban, isNull);
      expect(input.toJson().containsKey('iban'), isFalse);
      expect(input.specialty, 'Kaba yapı malzemeleri');
      expect(input.taxNumber, '5840123456');
      expect(input.notes, 'Çimento ve agrega ana tedarikçisi. Ödeme vadesi 30 gün.');
      expect(find.text('Tedarikçi kaydedildi.'), findsOneWidget);
      expect(find.text('Kaya Yapı A.Ş.'), findsWidgets);
    });

    testWidgets('server errors stay in the sheet (e.g. duplicate code 409)', (tester) async {
      final repo = FakeSuppliersRepository()
        ..writeError = const ApiException(
          statusCode: 409,
          message: 'bu tedarikçi kodu bu firmada zaten kullanılıyor',
          kind: ApiErrorKind.conflict,
        );
      await _pumpApp(tester, user: ownerUser, repo: repo);
      await tester.tap(find.text('Yeni Tedarikçi'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('supplier-code')), 'TED-001');
      await tester.enterText(find.byKey(const ValueKey('supplier-legal-name')), 'Kopya');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('bu tedarikçi kodu bu firmada zaten kullanılıyor'), findsOneWidget);
      expect(find.text('Kaydet'), findsOneWidget);
    });
  });

  group('routes & menu descriptor', () {
    test('menu entry points at the list route and requires the read permission', () {
      final entry = suppliersMenuEntries.single;
      expect(entry.label, 'Tedarikçiler');
      expect(entry.route, '/diger/tedarikciler');
      expect(entry.permission, 'organization.suppliers.read');
      expect(entry.icon, Icons.local_shipping_outlined);
    });

    test('routes are relative to /diger: list with a detail child', () {
      expect(suppliersRoutes, hasLength(1));
      expect(supplierDetailPath('a b'), '/diger/tedarikciler/a%20b');
    });
  });
}
