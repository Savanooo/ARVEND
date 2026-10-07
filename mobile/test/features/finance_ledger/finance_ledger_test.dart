import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/widgets/access_notices.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/finance_ledger/data/finance_ledger_repository.dart';
import 'package:arvend/features/projects/finance_ledger/domain/legacy_subcontractor.dart';
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

  group('Masraf onayı', () {
    testWidgets('bekleyen/reddedilen rozetli, ret gerekçesi satırda; toplam yalnızca onaylıyı sayar, üstte not', (
      tester,
    ) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      await _pump(
        tester,
        buildLedgerApp(user: ledgerOwner, client: client, expenses: approvalExpenses, home: _sections(cc.sampleProject())),
      );

      expect(find.text('Onay bekliyor'), findsOneWidget);
      expect(find.text('Reddedildi'), findsOneWidget);
      expect(find.text('Onaylandı'), findsNothing, reason: 'olağan (onaylı) satır rozetsiz');
      expect(find.text('Red nedeni: Fatura eksik'), findsOneWidget);
      expect(
        find.text('1 masraf onay bekliyor (toplam 3.250,50 TL). Onaylanana kadar toplamlara ve kâra girmez.'),
        findsOneWidget,
      );
      // Satır + geçerli toplam: bekleyen 3.250,50 ve reddedilen 18.000 sayılmaz.
      expect(find.text('84.500,00 TL'), findsNWidgets(2));
    });

    testWidgets('onay izni olmayan (finance.manage) bekleyen masrafta Onayla/Reddet görmez', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      await _pump(
        tester,
        buildLedgerApp(user: ledgerOwner, client: client, expenses: approvalExpenses, home: _sections(cc.sampleProject())),
      );

      await tester.tap(find.byKey(const ValueKey('masraf-e3')));
      await tester.pumpAndSettle();
      expect(find.text('Onay bekliyor'), findsWidgets);
      expect(find.widgetWithText(ElevatedButton, 'Onayla'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Reddet'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'İptal Et'), findsOneWidget, reason: 'iptal her durumda');
    });

    testWidgets('onaylayıcı: Onayla onay penceresinden sonra POST .../approve', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/expenses/e3/approve': [(status: 200, body: null)],
      });
      final client = await _client(adapter);
      await _pump(
        tester,
        buildLedgerApp(user: ledgerApprover, client: client, expenses: approvalExpenses, home: _sections(cc.sampleProject())),
      );

      await tester.tap(find.byKey(const ValueKey('masraf-e3')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Onayla'));
      await tester.pumpAndSettle();
      expect(adapter.calls, isEmpty, reason: 'önce onay penceresi');
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Onayla')));
      await tester.pumpAndSettle();

      expect(adapter.calls, ['/projects/p1/expenses/e3/approve']);
      expect(find.text('Masraf onaylandı.'), findsOneWidget);
    });

    testWidgets('onaylayıcı: Reddet gerekçe ister, POST .../reject {reason}', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/expenses/e3/reject': [(status: 200, body: null)],
      });
      final client = await _client(adapter);
      await _pump(
        tester,
        buildLedgerApp(user: ledgerApprover, client: client, expenses: approvalExpenses, home: _sections(cc.sampleProject())),
      );

      await tester.tap(find.byKey(const ValueKey('masraf-e3')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Reddet'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      final confirm = tester.widget<TextButton>(
        find.descendant(of: dialog, matching: find.widgetWithText(TextButton, 'Reddet')),
      );
      expect(confirm.onPressed, isNull, reason: 'gerekçe girilmeden ret kapalı');
      await tester.enterText(find.descendant(of: dialog, matching: find.byType(TextField)), 'Fiş yok');
      await tester.pump();
      await tester.tap(find.descendant(of: dialog, matching: find.text('Reddet')));
      await tester.pumpAndSettle();

      expect(adapter.calls, ['/projects/p1/expenses/e3/reject']);
      expect(adapter.requestBodies.single, {'reason': 'Fiş yok'});
      expect(find.text('Masraf reddedildi.'), findsOneWidget);
    });

    testWidgets('onaylayıcı: karar verilmiş masrafta düğme yok; reddedilende tarih + gerekçe', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      await _pump(
        tester,
        buildLedgerApp(user: ledgerApprover, client: client, expenses: approvalExpenses, home: _sections(cc.sampleProject())),
      );
      await tester.tap(find.byKey(const ValueKey('masraf-e4')));
      await tester.pumpAndSettle();
      expect(find.text('Fatura eksik'), findsOneWidget);
      expect(find.text('Reddedilme'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Onayla'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Reddet'), findsNothing);
    });

    testWidgets('onaylayıcı: kapalı projede Onayla/Reddet yok', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      final locked = cc.sampleProject(status: 'completed');
      await _pump(
        tester,
        buildLedgerApp(user: ledgerApprover, client: client, project: locked, expenses: approvalExpenses, home: _sections(locked)),
      );
      await tester.tap(find.byKey(const ValueKey('masraf-e3')));
      await tester.pumpAndSettle();
      expect(find.text('Ekip yemeği'), findsWidgets, reason: 'ayrıntı açıldı');
      expect(find.widgetWithText(ElevatedButton, 'Onayla'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Reddet'), findsNothing);
    });

    testWidgets('409 (başkası karar verdi): sunucu mesajı sayfada kalır', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/expenses/e3/approve': [
          (status: 409, body: {'error': 'yalnızca onay bekleyen bir masraf onaylanabilir veya reddedilebilir'}),
        ],
      });
      final client = await _client(adapter);
      await _pump(
        tester,
        buildLedgerApp(user: ledgerApprover, client: client, expenses: approvalExpenses, home: _sections(cc.sampleProject())),
      );

      await tester.tap(find.byKey(const ValueKey('masraf-e3')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Onayla'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Onayla')));
      await tester.pumpAndSettle();

      expect(find.text('yalnızca onay bekleyen bir masraf onaylanabilir veya reddedilebilir'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // Masraf KDV'si + düzenleme (backend migration 0065): reddedilen masraf
  // artık düzeltilip yeniden onaya gönderilebilir; PUT satırı bütünüyle
  // yeniden yazdığı için değişmeyen her alan aynen geri gider.
  group('Masraf düzenleme ve KDV', () {
    final rejectedWithVat = Expense.fromJson({
      'id': 'e5',
      'category': 'equipment',
      'description': 'Kırıcı kiralama',
      'amount': 18000,
      'currency': 'TRY',
      'expense_date': '2026-09-18',
      'supplier_name': 'Kiralama A.Ş.',
      'invoice_no': 'KR-77',
      'notes': 'İki gün',
      'change_order_id': 'co1',
      'cost_code_id': 'cc1',
      // Kullanıcının bütçe okuma izni yok: seçici görünmez ama bağ korunmalı.
      'budget_line_id': 'bl9',
      'vat_rate': 20,
      'vat_amount': 3000,
      'net_amount': 15000,
      'approval_status': 'rejected',
      'decided_at': '2026-09-19T08:30:00Z',
      'decision_note': 'Fatura eksik',
      'created_at': '2026-09-18T09:00:00Z',
    });

    Map<String, dynamic> updatedBody(String id, {double amount = 18000}) => {
          'id': id,
          'category': 'equipment',
          'description': 'Kırıcı kiralama',
          'amount': amount,
          'currency': 'TRY',
          'expense_date': '2026-09-18',
          'approval_status': 'pending',
          'created_at': '2026-09-18T09:00:00Z',
        };

    Future<void> openEdit(WidgetTester tester, String expenseId) async {
      await tester.tap(find.byKey(ValueKey('masraf-$expenseId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('masraf-duzenle')));
      await tester.pumpAndSettle();
      expect(find.text('Masrafı Düzenle'), findsOneWidget);
    }

    Future<void> tapSave(WidgetTester tester) async {
      final save = find.widgetWithText(ElevatedButton, 'Kaydet');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
    }

    testWidgets('ayrıntı KDV oranını, KDV tutarını ve KDV hariç tutarı gösterir; oran yoksa "Belirtilmedi"', (
      tester,
    ) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      await _pump(
        tester,
        buildLedgerApp(
          user: ledgerOwner,
          client: client,
          expenses: [rejectedWithVat, ...ledgerExpenses],
          home: _sections(cc.sampleProject()),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('masraf-e5')));
      await tester.pumpAndSettle();
      expect(find.text('KDV (%20)'), findsOneWidget);
      expect(find.text('3.000,00 TL'), findsOneWidget);
      expect(find.text('KDV hariç'), findsOneWidget);
      expect(find.text('15.000,00 TL'), findsOneWidget);
      Navigator.of(tester.element(find.text('KDV (%20)'))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('masraf-e1')));
      await tester.pumpAndSettle();
      expect(find.text('Belirtilmedi'), findsOneWidget);
      expect(find.text('KDV hariç'), findsNothing);
    });

    testWidgets('reddedilen masraf: Düzenle formu dolu açar, değişmeyen alanlar aynen PUT edilir, yeniden onaya gider', (
      tester,
    ) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/expenses/e5': [(status: 200, body: updatedBody('e5', amount: 24000))],
      });
      final client = await _client(adapter);
      await _pump(
        tester,
        buildLedgerApp(user: ledgerOwner, client: client, expenses: [rejectedWithVat], home: _sections(cc.sampleProject())),
      );
      await openEdit(tester, 'e5');

      // Ret gerekçesi formda: neyin düzeltileceği belli.
      expect(find.text('Red nedeni: Fatura eksik. Düzeltip kaydedince yeniden onaya gider.'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Kırıcı kiralama'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '18000'), findsOneWidget);
      expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('masraf-kdv-20'))).selected, isTrue);
      expect(find.text('KDV hariç: 15.000,00 TL · KDV: 3.000,00 TL'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextFormField, 'Tutar (TRY)'), '24.000');
      await tester.pump();
      expect(find.text('KDV hariç: 20.000,00 TL · KDV: 4.000,00 TL'), findsOneWidget);
      await tapSave(tester);

      expect(find.byType(AlertDialog), findsNothing, reason: 'reddedilen masrafta onay sorusu yok');
      expect(adapter.calls, ['/projects/p1/expenses/e5']);
      expect(adapter.methods, ['PUT']);
      expect(adapter.requestBodies.single, {
        'category': 'equipment',
        'description': 'Kırıcı kiralama',
        'amount': 24000,
        'currency': 'TRY',
        'expense_date': '2026-09-18',
        'supplier_name': 'Kiralama A.Ş.',
        'invoice_no': 'KR-77',
        'notes': 'İki gün',
        'change_order_id': 'co1',
        'cost_code_id': 'cc1',
        'budget_line_id': 'bl9',
        'vat_rate': 20,
      });
      expect(find.text('Masraf güncellendi; yeniden onaya gönderildi.'), findsOneWidget);
      expect(find.text('Masrafı Düzenle'), findsNothing, reason: 'form kapandı');
      expect(find.byKey(const ValueKey('masraf-duzenle')), findsNothing, reason: 'ayrıntı da kapandı');
    });

    testWidgets('onaylı masraf: kayıttan önce yeniden onaya gideceği sorulur; Vazgeç istek atmaz', (tester) async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/expenses/e1': [(status: 200, body: updatedBody('e1'))],
      });
      final client = await _client(adapter);
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, home: _sections(cc.sampleProject())));
      await openEdit(tester, 'e1');
      expect(find.text('Kaydedince masraf yeniden onaya gider.'), findsOneWidget);

      await tapSave(tester);
      expect(find.text('Yeniden onaya gidecek'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Vazgeç')));
      await tester.pumpAndSettle();
      expect(adapter.calls, isEmpty, reason: 'vazgeçince istek yok');
      expect(find.text('Masrafı Düzenle'), findsOneWidget, reason: 'form açık kalır');

      await tapSave(tester);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Kaydet')));
      await tester.pumpAndSettle();
      expect(adapter.methods, ['PUT']);
      final body = adapter.requestBodies.single as Map<String, dynamic>;
      expect(body['amount'], 84500);
      expect(body['change_order_id'], 'co1');
      expect(body['cost_code_id'], 'cc1');
      expect(body['budget_line_id'], '');
      expect(body['supplier_name'], 'Yapı Market');
      expect(body['notes'], 'Zemin kat için ikinci sevkiyat');
      expect(body.containsKey('vat_rate'), isFalse, reason: 'belirtilmemiş KDV belirtilmemiş kalır');
      expect(find.text('Masraf güncellendi; yeniden onaya gönderildi.'), findsOneWidget);
    });

    testWidgets('Düzenle: yalnızca finance.manage + açık proje + iptal edilmemiş masrafta', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, home: _sections(cc.sampleProject())));
      await tester.tap(find.byKey(const ValueKey('masraf-e2')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget, reason: 'ayrıntı açıldı');
      expect(find.byKey(const ValueKey('masraf-duzenle')), findsNothing, reason: 'iptal edilmiş masraf');

      // Aynı masraf açık projede sahibe Düzenle gösterir (aşağıdaki
      // "yok"ların boşuna geçmediğinin kanıtı).
      for (final (user, project, visible) in [
        (ledgerOwner, cc.sampleProject(), true),
        (ledgerViewer, cc.sampleProject(), false),
        (ledgerOwner, cc.sampleProject(status: 'completed'), false),
      ]) {
        // Önceki ağacın açık sayfası yeni ağaca taşınmasın.
        await tester.pumpWidget(const SizedBox());
        await _pump(
          tester,
          buildLedgerApp(user: user, client: client, project: project, home: _sections(project)),
        );
        await tester.tap(find.byKey(const ValueKey('masraf-e1')));
        await tester.pumpAndSettle();
        expect(find.text('Alçıpan ve profil'), findsWidgets, reason: 'ayrıntı açıldı');
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(
          find.byKey(const ValueKey('masraf-duzenle')),
          visible ? findsOneWidget : findsNothing,
          reason: '${user.id} / ${project.status}',
        );
      }
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

    testWidgets('taşeron ekle: kâr payı girilince kârımız ve müşteriye yansıyan önizlenir ve gönderilir', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      final repo = FakeFinanceLedgerRepository();
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, repo: repo, home: tab(cc.sampleProject())));

      await tester.tap(find.text('Taşeron Ekle'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Taşeron adı'), 'Kaya Alçı');
      await tester.enterText(find.widgetWithText(TextFormField, 'Sözleşme bedeli (TRY)'), '100.000');
      await tester.enterText(find.byKey(const Key('legacy-subcontractor-profit')), '20');
      await tester.pumpAndSettle();
      final preview = tester.widget<Text>(find.textContaining('Kârımız')).data!;
      expect(preview, contains('20.000'));
      expect(preview, contains('Müşteriye yansıyan'));
      expect(preview, contains('120.000'));

      await tester.enterText(find.byKey(const Key('legacy-subcontractor-profit')), '1500');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Taşeron Ekle'));
      await tester.pumpAndSettle();
      expect(find.text('0 ile 1000 arasında bir yüzde gir'), findsOneWidget);
      expect(repo.createdSubcontractors, isEmpty);

      await tester.enterText(find.byKey(const Key('legacy-subcontractor-profit')), '20');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Taşeron Ekle'));
      await tester.pumpAndSettle();
      expect(repo.createdSubcontractors.single['profit_percent'], 20.0);
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

    testWidgets('taşeron düzenle: mevcut değerlerle açılır, Türkçe bedel ile kaydedilir', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      final repo = FakeFinanceLedgerRepository();
      final project = cc.sampleProject();
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, repo: repo, home: tab(project)));

      await tester.tap(find.byKey(const ValueKey('legacy-subcontractor-edit-s1')));
      await tester.pumpAndSettle();
      expect(find.text('Taşeronu Düzenle'), findsOneWidget);
      expect(find.text('180000'), findsOneWidget, reason: 'mevcut bedel alana yazılır');

      await tester.enterText(find.widgetWithText(TextFormField, 'Taşeron adı'), 'Yılmaz Elektrik Taahhüt');
      await tester.enterText(find.widgetWithText(TextFormField, 'Sözleşme bedeli (TRY)'), '195.000,50');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
      await tester.pumpAndSettle();

      final body = repo.updatedSubcontractors.single;
      expect(body['id'], 's1');
      expect(body['name'], 'Yılmaz Elektrik Taahhüt');
      expect(body['company_name'], 'Yılmaz Elektrik Taahhüt Ltd.');
      expect(body['work_description'], 'Zemin kat elektrik tesisatı');
      expect(body['contract_amount'], 195000.5);
      expect(find.text('Taşeron güncellendi.'), findsOneWidget);
    });

    testWidgets('taşeron düzenle: bedel ödenen tutarın altına indirilemez', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      final repo = FakeFinanceLedgerRepository();
      final project = cc.sampleProject();
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, repo: repo, home: tab(project)));

      await tester.tap(find.byKey(const ValueKey('legacy-subcontractor-edit-s1')));
      await tester.pumpAndSettle();
      // Yılmaz Elektrik'e 120.000 ödenmiş.
      await tester.enterText(find.widgetWithText(TextFormField, 'Sözleşme bedeli (TRY)'), '100.000');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
      await tester.pumpAndSettle();

      expect(find.textContaining('altına indirilemez'), findsOneWidget);
      expect(repo.updatedSubcontractors, isEmpty);
    });

    testWidgets('ödeme ayrıntısı: gerekçeyle iptal edilir', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      final repo = FakeFinanceLedgerRepository();
      final project = cc.sampleProject();
      await _pump(tester, buildLedgerApp(user: ledgerOwner, client: client, repo: repo, home: tab(project)));

      await tester.tap(find.byKey(const ValueKey('legacy-payment-sp1')));
      await tester.pumpAndSettle();
      expect(find.text('Taşeron Ödemesi'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'İptal Et'));
      await tester.pumpAndSettle();
      await _confirmReason(tester, 'Mükerrer kayıt');

      expect(repo.voidedPayments.single, {'payment_id': 'sp1', 'reason': 'Mükerrer kayıt'});
      expect(find.text('Ödeme iptal edildi.'), findsOneWidget);
    });

    testWidgets('salt-okur: düzenleme yok, ödeme ayrıntısı açılır ama iptal yok', (tester) async {
      final client = await _client(FakeHttpClientAdapter(script: {}));
      await _pump(tester, buildLedgerApp(user: ledgerViewer, client: client, home: tab(cc.sampleProject())));

      expect(find.byKey(const ValueKey('legacy-subcontractor-edit-s1')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('legacy-payment-sp1')));
      await tester.pumpAndSettle();
      expect(find.text('Taşeron Ödemesi'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'İptal Et'), findsNothing);
    });

    test('depo: düzenleme formda olmayan alanları aynen geri gönderir; iptal doğru uca gider', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/projects/p1/subcontractors/s1': [
          (status: 200, body: {'id': 's1', 'name': 'Yeni Ad', 'contract_amount': 200000, 'status': 'active'}),
        ],
        '/projects/p1/subcontractor-payments/sp1/void': [(status: 200, body: null)],
      });
      final repo = FinanceLedgerRepository(await _client(adapter));
      const existing = LegacySubcontractor(
        id: 's1',
        name: 'Eski Ad',
        companyName: 'Firma',
        workDescription: 'İş',
        contractAmount: 180000,
        paidAmount: 0,
        remainingAmount: 180000,
        currency: 'TRY',
        status: 'completed',
        phone: '5551112233',
        email: 'usta@ornek.com',
        notes: 'Not',
        startDate: '2026-09-01',
        endDate: '2026-12-01',
        costCodeId: 'cc1',
      );

      await repo.updateSubcontractor(
        'p1',
        existing,
        name: 'Yeni Ad',
        companyName: 'Firma',
        workDescription: 'İş',
        contractAmount: 200000,
      );
      expect(adapter.requestBodies.first, {
        'name': 'Yeni Ad',
        'company_name': 'Firma',
        'work_description': 'İş',
        'contract_amount': 200000.0,
        'currency': 'TRY',
        'phone': '5551112233',
        'email': 'usta@ornek.com',
        'start_date': '2026-09-01',
        'end_date': '2026-12-01',
        'status': 'completed',
        'notes': 'Not',
        'cost_code_id': 'cc1',
        // Kâr payı formda değiştirilmediyse null: sunucu mevcut değeri korur.
        'profit_percent': null,
      });

      await repo.voidSubcontractorPayment('p1', 'sp1', reason: 'Mükerrer');
      expect(adapter.calls.last, '/projects/p1/subcontractor-payments/sp1/void');
      expect(adapter.requestBodies.last, {'reason': 'Mükerrer'});
    });
  });
}
