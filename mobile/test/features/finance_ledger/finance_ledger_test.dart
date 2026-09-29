import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/widgets/access_notices.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/finance_ledger/presentation/ledger_sections.dart';
import 'package:arvend/features/projects/finance_ledger/presentation/subcontractor_payments_tab.dart';
import 'package:arvend/features/projects/domain/project_lock_text.dart';

import '../../test_utils/fake_api_client.dart';
import '../contract_co/contract_co_test_support.dart' as cc;
import 'finance_ledger_test_support.dart';

/// Proje Finans defteri: Masraflar/Tahsilatlar satır ayrıntısı + iptal
/// (gerekçeli), bağ etiketleri (ek iş, maliyet kodu, ödeme planı kalemi),
/// kilitli proje, salt-okur ve legacy "Taşeron Ödemeleri".

Widget _sections(Project project) => Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          LedgerLockedNotice(project: project),
          ExpensesLedgerSection(project: project),
          const SizedBox(height: 24),
          CollectionsLedgerSection(project: project),
        ],
      ),
    );

Future<void> _pump(WidgetTester tester, Widget app) async {
  await tester.binding.setSurfaceSize(const Size(400, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(app);
  await tester.pumpAndSettle();
}

Future<ApiClient> _client(FakeHttpClientAdapter adapter) => buildFakeApiClient(adapter);

Future<void> _confirmReason(WidgetTester tester, String reason) async {
  final dialog = find.byType(AlertDialog);
  expect(dialog, findsOneWidget);
  await tester.enterText(find.descendant(of: dialog, matching: find.byType(TextField)), reason);
  await tester.pump();
  await tester.tap(find.descendant(of: dialog, matching: find.text('İptal Et')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  group('Masraflar / Tahsilatlar', () {
    testWidgets('satırlar: iptal gerekçesi, ek iş no, plan kalemi; geçerli toplam iptali saymaz', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      final project = cc.sampleProject();
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, home: _sections(project)));

      expect(find.text('İPTAL · Mükerrer giriş'), findsOneWidget);
      expect(find.textContaining('EK-2026-0003'), findsOneWidget);
      expect(find.textContaining('Peşinat'), findsWidgets);
      expect(find.text('84.500,00 TL'), findsNWidgets(2), reason: 'satır + geçerli toplam (12.000 iptal edildi)');
      expect(find.text('Masraf Ekle'), findsOneWidget);
      expect(find.text('Tahsilat Ekle'), findsOneWidget);
    });

    testWidgets('masraf ayrıntısı bağları gösterir; gerekçeyle iptal POST .../void {reason} atar', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/expenses/e1/void': [(status: 200, body: null)],
      });
      final client = await _client(adapter);
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, home: _sections(cc.sampleProject())));

      await tester.tap(find.byKey(const ValueKey('masraf-e1')));
      await tester.pumpAndSettle();
      expect(find.text('EK-2026-0003 · Toplantı odası cam bölme'), findsOneWidget);
      expect(find.text('03.20 — Kuru duvar'), findsOneWidget);
      expect(find.text('Zemin kat için ikinci sevkiyat'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'İptal Et'));
      await tester.pumpAndSettle();
      // Gerekçe girilmeden onay kapalı.
      final confirm = tester.widget<TextButton>(
        find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, 'İptal Et')),
      );
      expect(confirm.onPressed, isNull);
      await _confirmReason(tester, 'Tedarikçi iade etti');

      expect(adapter.calls, ['/projects/p1/expenses/e1/void']);
      expect(adapter.requestBodies.single, {'reason': 'Tedarikçi iade etti'});
      expect(find.text('Masraf iptal edildi.'), findsOneWidget);
    });

    testWidgets('tahsilat ayrıntısı plan kalemini gösterir; iptal .../collections/{id}/void', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/collections/c1/void': [(status: 200, body: null)],
      });
      final client = await _client(adapter);
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, home: _sections(cc.sampleProject())));

      await tester.tap(find.byKey(const ValueKey('tahsilat-c1')));
      await tester.pumpAndSettle();
      expect(find.text('Ödeme Planı Kalemi'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'İptal Et'));
      await tester.pumpAndSettle();
      await _confirmReason(tester, 'Banka iadesi');

      expect(adapter.calls, ['/projects/p1/collections/c1/void']);
      expect(adapter.requestBodies.single, {'reason': 'Banka iadesi'});
      expect(find.text('Tahsilat iptal edildi.'), findsOneWidget);
    });

    testWidgets('409: sunucu mesajı sayfada kalır, çökme yok', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/expenses/e1/void': [
          (status: 409, body: {'error': 'Proje tamamlandı; finans hareketleri kilitli.'}),
        ],
      });
      final client = await _client(adapter);
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, home: _sections(cc.sampleProject())));

      await tester.tap(find.byKey(const ValueKey('masraf-e1')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'İptal Et'));
      await tester.pumpAndSettle();
      await _confirmReason(tester, 'Deneme');

      expect(find.text('Proje tamamlandı; finans hareketleri kilitli.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('iptal edilmiş kayıtta "İptal Et" yok', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, home: _sections(cc.sampleProject())));

      await tester.tap(find.byKey(const ValueKey('masraf-e2')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, 'İptal Et'), findsNothing);
    });

    testWidgets('salt-okur (finance.read): ekle/iptal yok, ayrıntı açılır', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      await _pump(tester, buildLedgerApp(user: ledgerViewer, client: client, home: _sections(cc.sampleProject())));

      expect(find.text('Masraf Ekle'), findsNothing);
      expect(find.text('Tahsilat Ekle'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('masraf-e1')));
      await tester.pumpAndSettle();
      expect(find.text('Alçıpan ve profil'), findsWidgets);
      expect(find.widgetWithText(OutlinedButton, 'İptal Et'), findsNothing);
      // Maliyet kataloğu izni yok -> kod adı yerine nötr etiket.
      expect(find.text('Maliyet kodu'), findsOneWidget);
    });

    testWidgets('tamamlanmış proje: kilit notu, ekle/iptal yok', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      final project = cc.sampleProject(status: 'completed');
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, project: project, home: _sections(project)));

      expect(find.text(kProjectLockedNoticeText), findsOneWidget);
      expect(find.text('Masraf Ekle'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tahsilat-c1')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, 'İptal Et'), findsNothing);
    });
  });

  group('Taşeron Ödemeleri (legacy)', () {
    Widget tab(Project project) => Scaffold(body: SubcontractorPaymentsTab(projectId: project.id, project: project));

    testWidgets('sahip: kartlar, sunucu tutarları, iptal edilmiş ödeme listelenmez, ekle düğmeleri', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      final project = cc.sampleProject();
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, home: tab(project)));

      expect(find.text('Yılmaz Elektrik'), findsOneWidget);
      expect(find.text('Demir Boya'), findsOneWidget);
      expect(find.text('Taşeron Ekle'), findsOneWidget);
      expect(find.text('Ödeme Ekle'), findsNWidgets(2));
      expect(find.textContaining('1. ödeme'), findsOneWidget);
      expect(find.textContaining('Yanlış giriş'), findsNothing);
    });

    testWidgets('ödeme ekle: Türkçe tutar, taşeron başına idempotency anahtarı', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      final repo = FakeFinanceLedgerRepository();
      final project = cc.sampleProject();
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, repo: repo, home: tab(project)));

      await tester.tap(find.text('Ödeme Ekle').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), '15.000,50');
      await tester.enterText(find.widgetWithText(TextFormField, 'Açıklama (opsiyonel)'), '3. ödeme');
      await tester.tap(find.text('Ödeme Kaydet'));
      await tester.pumpAndSettle();

      final body = repo.createdPayments.single;
      expect(body['subcontractor_id'], 's1');
      expect(body['amount'], 15000.5);
      expect(body['description'], '3. ödeme');
      expect(body['idempotency_key'] as String, startsWith('subpay-s1-'));
      expect(find.text('Ödeme kaydedildi.'), findsOneWidget);
    });

    testWidgets('taşeron ekle: ad zorunlu, sonra kaydedilir', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      final repo = FakeFinanceLedgerRepository();
      final project = cc.sampleProject();
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, repo: repo, home: tab(project)));

      await tester.tap(find.text('Taşeron Ekle'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Taşeron Ekle'));
      await tester.pumpAndSettle();
      expect(find.text('Taşeron adı gerekli'), findsOneWidget);
      expect(repo.createdSubcontractors, isEmpty);

      await tester.enterText(find.widgetWithText(TextFormField, 'Taşeron adı'), 'Kaya Alçı');
      await tester.enterText(find.widgetWithText(TextFormField, 'Sözleşme bedeli (TRY)'), '64.000');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Taşeron Ekle'));
      await tester.pumpAndSettle();
      expect(repo.createdSubcontractors.single['name'], 'Kaya Alçı');
      expect(repo.createdSubcontractors.single['contract_amount'], 64000.0);
      expect(find.text('Taşeron eklendi.'), findsOneWidget);
    });

    testWidgets('salt-okur: ekleme düğmesi yok', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      await _pump(tester, buildLedgerApp(user: ledgerViewer, client: client, home: tab(cc.sampleProject())));
      expect(find.text('Taşeron Ekle'), findsNothing);
      expect(find.text('Ödeme Ekle'), findsNothing);
      expect(find.text('Yılmaz Elektrik'), findsOneWidget);
    });

    testWidgets('finans izni yok: istek atılmaz, "Yetkin yok"', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      final repo = FakeFinanceLedgerRepository();
      await _pump(tester, buildLedgerApp(user: ledgerPm, client: client, repo: repo, home: tab(cc.sampleProject())));
      expect(find.byType(NoAccessView), findsOneWidget);
      expect(repo.calls, isEmpty);
      expect(find.textContaining('TL'), findsNothing);
    });

    testWidgets('sunucu 403: "Yetkin yok", çökme yok', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      final repo = FakeFinanceLedgerRepository(listError: ledgerForbidden);
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, repo: repo, home: tab(cc.sampleProject())));
      expect(find.byType(NoAccessView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('iptal edilmiş proje: kilit notu, ekleme yok', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      final project = cc.sampleProject(status: 'cancelled');
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, project: project, home: tab(project)));
      expect(find.text(kProjectLockedNoticeText), findsOneWidget);
      expect(find.text('Taşeron Ekle'), findsNothing);
      expect(find.text('Ödeme Ekle'), findsNothing);
    });
  });
}
