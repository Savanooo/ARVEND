import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/widgets/access_notices.dart';
import 'package:arvend/core/widgets/status_badge.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/finance_plan/domain/project_invoice.dart';
import 'package:arvend/features/projects/finance_plan/finance_plan_routes.dart';
import 'package:arvend/features/projects/domain/project_lock_text.dart';
import 'package:arvend/features/projects/finance_plan/presentation/widgets/finance_plan_ui.dart'
    show kPaymentPlanReadOnlyText;

import 'finance_plan_test_support.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  Future<void> pumpApp(
    WidgetTester tester, {
    required User user,
    required FakeFinancePlanRepository repo,
    required String location,
    Project Function()? project,
    List<int>? projectCounter,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildFinancePlanApp(
      user: user,
      repo: repo,
      location: location,
      project: project,
      projectCounter: projectCounter,
    ));
    await tester.pumpAndSettle();
  }

  const planPath = '/projeler/$kProjectId/odeme-plani';
  const invoicesListPath = '/projeler/$kProjectId/faturalar';

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  group('Ödeme Planı listesi', () {
    testWidgets('izin yoksa API çağrılmaz, yetki mesajı gösterilir', (tester) async {
      final repo = FakeFinancePlanRepository();
      await pumpApp(tester, user: fpNoAccessUser, repo: repo, location: planPath);
      expect(find.byType(NoAccessView), findsOneWidget);
      expect(repo.calls, isEmpty);
      // Hiçbir tutar görünmez.
      expect(find.textContaining('TL'), findsNothing);
    });

    testWidgets('sahip: özet, gecikme vurgusu, planlanmamış bakiye ve "Kalem Ekle"', (tester) async {
      final repo = FakeFinancePlanRepository();
      await pumpApp(tester, user: fpOwnerUser, repo: repo, location: planPath);
      expect(repo.calls, contains('plan:$kProjectId'));
      expect(find.text('1.250.000,00 TL'), findsOneWidget);
      expect(find.text('400.000,00 TL'), findsOneWidget);
      expect(find.text('Kalem Ekle'), findsOneWidget);
      expect(find.text('14 gün gecikti'), findsOneWidget);
      expect(find.text('Gecikti'), findsOneWidget);
      expect(find.textContaining('150.000,00 TL planlanmamış bakiye'), findsOneWidget);
      expect(find.byType(ReadOnlyNotice), findsNothing);
    });

    testWidgets('salt-okunur: ekleme yok, bilgi kutusu var', (tester) async {
      await pumpApp(tester, user: fpReadOnlyUser, repo: FakeFinancePlanRepository(), location: planPath);
      expect(find.text('Kalem Ekle'), findsNothing);
      expect(find.text(kPaymentPlanReadOnlyText), findsOneWidget);
    });

    testWidgets('sunucu 403 dönerse ekran çökmez, yetki mesajı gösterir', (tester) async {
      final repo = FakeFinancePlanRepository()..planError = forbidden;
      await pumpApp(tester, user: fpOwnerUser, repo: repo, location: planPath);
      expect(tester.takeException(), isNull);
      expect(find.byType(NoAccessView), findsOneWidget);
    });

    testWidgets('tamamlanmış projede yazma aksiyonu yok, kilit notu var', (tester) async {
      await pumpApp(
        tester,
        user: fpManagerUser,
        repo: FakeFinancePlanRepository(),
        location: planPath,
        project: () => financeProject(status: 'completed'),
      );
      expect(find.text('Kalem Ekle'), findsNothing);
      expect(find.text(kProjectLockedNoticeText), findsOneWidget);
    });

    testWidgets('boş plan', (tester) async {
      await pumpApp(tester, user: fpManagerUser, repo: FakeFinancePlanRepository(items: const []), location: planPath);
      expect(find.text('Henüz ödeme planı kalemi yok.'), findsOneWidget);
      expect(find.text('Kalem Ekle'), findsOneWidget);
    });
  });

  group('Ödeme planı formu', () {
    testWidgets('boş gönderimde doğrulama; tutarla ekleme listeye döner ve sırayı sona koyar', (tester) async {
      final repo = FakeFinancePlanRepository();
      await pumpApp(tester, user: fpManagerUser, repo: repo, location: planPath);
      await tester.tap(find.text('Kalem Ekle'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Kalemi Ekle'));
      await tester.pumpAndSettle();
      expect(find.text('Kalem adı zorunludur'), findsOneWidget);
      expect(find.text('Tutar sıfırdan büyük olmalıdır'), findsOneWidget);
      expect(repo.createdItems, isEmpty);

      await tester.enterText(find.byKey(const ValueKey('plan-item-name')), 'Teslim Ödemesi');
      await tester.enterText(find.byKey(const ValueKey('plan-item-amount')), '150.000,50');
      await tester.pumpAndSettle();
      expect(find.text('150.000,50 TL'), findsOneWidget); // canlı biçim önizlemesi
      await tester.tap(find.text('Kalemi Ekle'));
      await tester.pumpAndSettle();

      expect(repo.createdItems, hasLength(1));
      final input = repo.createdItems.single;
      expect(input.name, 'Teslim Ödemesi');
      expect(input.plannedAmount, 150000.5);
      expect(input.percentage, isNull);
      expect(input.sortOrder, kPlanItemFixtures.length);
      expect(input.dueDate, isNull);
      // Listeye döndü, yeni kalem görünür.
      expect(find.text('Ödeme planı kalemi eklendi.'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Teslim Ödemesi'), 200, scrollable: find.byType(Scrollable).last);
      expect(find.text('Teslim Ödemesi'), findsOneWidget);
    });

    testWidgets('yüzde ile ekleme planned_amount göndermez', (tester) async {
      final repo = FakeFinancePlanRepository();
      await pumpApp(tester, user: fpOwnerUser, repo: repo, location: paymentPlanNewPath(kProjectId));
      await tester.enterText(find.byKey(const ValueKey('plan-item-name')), 'Ara Ödeme');
      await tester.tap(find.text('Yüzde'));
      await tester.pumpAndSettle();
      expect(find.textContaining('ana sözleşme bedeli (1.250.000,00 TL)'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('plan-item-percentage')), '12,5');
      await tester.tap(find.text('Kalemi Ekle'));
      await tester.pumpAndSettle();
      final input = repo.createdItems.single;
      expect(input.percentage, 12.5);
      expect(input.plannedAmount, isNull);
      expect(input.toJson().containsKey('planned_amount'), isFalse);
    });

    testWidgets('yüzde: "33.333" ve %100 üstü reddedilir; geçerli yüzdede tutar önizlenir', (tester) async {
      final repo = FakeFinancePlanRepository();
      await pumpApp(tester, user: fpOwnerUser, repo: repo, location: paymentPlanNewPath(kProjectId));
      await tester.enterText(find.byKey(const ValueKey('plan-item-name')), 'Ara Ödeme');
      await tester.tap(find.text('Yüzde'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('plan-item-percentage')), '33.333');
      await tester.tap(find.text('Kalemi Ekle'));
      await tester.pumpAndSettle();
      expect(find.text('Geçerli bir yüzde gir (ör. 12,5 ya da 33,33)'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('plan-item-percentage')), '150');
      await tester.tap(find.text('Kalemi Ekle'));
      await tester.pumpAndSettle();
      expect(find.text('Yüzde en fazla 100 olabilir'), findsOneWidget);
      expect(repo.createdItems, isEmpty);
      await tester.enterText(find.byKey(const ValueKey('plan-item-percentage')), '12.5');
      await tester.pump();
      expect(find.textContaining('= 156.250,00 TL'), findsOneWidget);
    });

    testWidgets('düzenleme: mevcut değerler dolu gelir, sıra/vade/not korunur', (tester) async {
      final repo = FakeFinancePlanRepository();
      await pumpApp(tester, user: fpOwnerUser, repo: repo, location: paymentPlanItemPath(kProjectId, 'i2'));
      // Tek düzenleme yolu aksiyon çubuğunda (AppBar'da ikinci bir kalem yok).
      expect(find.byTooltip('Düzenle'), findsNothing);
      await tapVisible(tester, find.widgetWithText(OutlinedButton, 'Düzenle'));

      expect(find.text('1. Hakediş'), findsWidgets);
      expect(find.byKey(const ValueKey('plan-item-percentage')), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('plan-item-name')), '1. Hakediş (Kaba)');
      await tapVisible(tester, find.text('Değişiklikleri Kaydet'));

      expect(repo.updatedItems, hasLength(1));
      final (id, input) = repo.updatedItems.single;
      expect(id, 'i2');
      expect(input.name, '1. Hakediş (Kaba)');
      expect(input.percentage, 30);
      expect(input.sortOrder, 1);
      expect(input.dueDate, '2026-09-15');
      expect(input.notes, kPlanItemFixtures[1].notes);
      expect(find.text('Ödeme planı kalemi güncellendi.'), findsOneWidget);
    });

    testWidgets('409 (proje kilitlendi): hata gösterilir, proje durumu tazelenir', (tester) async {
      final repo = FakeFinancePlanRepository()..writeError = conflictLocked;
      final counter = <int>[];
      await pumpApp(
        tester,
        user: fpOwnerUser,
        repo: repo,
        location: paymentPlanNewPath(kProjectId),
        projectCounter: counter,
      );
      final before = counter.length;
      await tester.enterText(find.byKey(const ValueKey('plan-item-name')), 'X');
      await tester.enterText(find.byKey(const ValueKey('plan-item-amount')), '10');
      await tester.tap(find.text('Kalemi Ekle'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('yeni finans hareketi oluşturulamaz'), findsOneWidget);
      expect(counter.length, greaterThan(before));
    });

    testWidgets('yönetme izni yoksa form açılmaz', (tester) async {
      final repo = FakeFinancePlanRepository();
      await pumpApp(tester, user: fpReadOnlyUser, repo: repo, location: paymentPlanNewPath(kProjectId));
      expect(find.byType(NoAccessView), findsOneWidget);
      expect(find.text('Kalemi Ekle'), findsNothing);
      // Alttaki proje sayfasının özet bölümü planı okuyabilir; yazma yok.
      expect(repo.calls.where((c) => !c.startsWith('plan:') && !c.startsWith('invoices:')), isEmpty);
    });

    testWidgets('kaydedilmemiş değişiklikle geri dönerken onay sorulur', (tester) async {
      await pumpApp(tester, user: fpOwnerUser, repo: FakeFinancePlanRepository(), location: planPath);
      await tester.tap(find.text('Kalem Ekle'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('plan-item-name')), 'Yarım');
      await tester.pump();
      // Android geri hareketi (PopScope'a uğrar).
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Kaydedilmemiş değişiklikler'), findsOneWidget);
      await tester.tap(find.text('Çık'));
      await tester.pumpAndSettle();
      expect(find.text('Plan Toplamı'), findsOneWidget);
    });
  });

  group('Ödeme planı kalemi detayı', () {
    testWidgets('bağlı tahsilatlar listelenir (iptal edilen hariç); "Tahsilat Ekle" formu bu kaleme bağlı açar', (
      tester,
    ) async {
      await pumpApp(tester, user: fpOwnerUser, repo: FakeFinancePlanRepository(), location: paymentPlanItemPath(kProjectId, 'i2'));
      final linked = find.byKey(const ValueKey('plan-item-linked-collections'));
      expect(find.descendant(of: linked, matching: find.text('10.09.2026 · EFT')), findsOneWidget);
      expect(find.descendant(of: linked, matching: find.text('24.09.2026 · Çek')), findsOneWidget);
      expect(find.descendant(of: linked, matching: find.text('20.09.2026 · EFT')), findsNothing, reason: 'iptal edildi');
      // Açık bakiyeli kalemde olağan sonraki adım birincil aksiyon.
      expect(find.widgetWithText(ElevatedButton, 'Tahsilat Ekle'), findsOneWidget);
      await tapVisible(tester, find.widgetWithText(ElevatedButton, 'Tahsilat Ekle'));
      final sheet = find.byType(BottomSheet);
      expect(sheet, findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.textContaining('1. Hakediş · kalan')), findsOneWidget);
    });

    testWidgets('tamamen tahsil edilmiş kalemde "Tahsilat Ekle" yok, Düzenle birincil', (tester) async {
      await pumpApp(tester, user: fpOwnerUser, repo: FakeFinancePlanRepository(), location: paymentPlanItemPath(kProjectId, 'i1'));
      expect(find.text('Tahsilat Ekle'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Düzenle'), findsOneWidget);
    });

    testWidgets('salt-okunur kullanıcı aksiyon görmez', (tester) async {
      await pumpApp(tester, user: fpReadOnlyUser, repo: FakeFinancePlanRepository(), location: planPath);
      // Kalem adı yüzdeyle birlikte tek bir zengin metindir.
      await tester.tap(find.textContaining('1. Hakediş'));
      await tester.pumpAndSettle();
      expect(find.text('225.000,00 TL'), findsOneWidget);
      expect(find.byTooltip('Düzenle'), findsNothing);
      expect(find.text('Kalemi İptal Et'), findsNothing);
    });

    testWidgets('iptal: onaydan sonra DELETE, kalem "İptal" olur ve aksiyonlar kalkar', (tester) async {
      final repo = FakeFinancePlanRepository();
      await pumpApp(tester, user: fpOwnerUser, repo: repo, location: paymentPlanItemPath(kProjectId, 'i3'));
      await tapVisible(tester, find.text('Kalemi İptal Et'));
      expect(find.textContaining('Bu işlem geri alınamaz'), findsOneWidget);

      // Vazgeç -> çağrı yok.
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(repo.calls.where((c) => c.startsWith('cancelItem')), isEmpty);

      await tapVisible(tester, find.text('Kalemi İptal Et'));
      await tester.tap(find.text('İptal Et'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('cancelItem:i3'));
      expect(find.text('Ödeme planı kalemi iptal edildi.'), findsOneWidget);
      expect(find.text('İptal'), findsOneWidget);
      expect(find.text('Kalemi İptal Et'), findsNothing);
      expect(find.byTooltip('Düzenle'), findsNothing);
    });

    testWidgets('iptal sırasında 403: çökmez, mesaj gösterir', (tester) async {
      final repo = FakeFinancePlanRepository()..writeError = forbidden;
      await pumpApp(tester, user: fpOwnerUser, repo: repo, location: paymentPlanItemPath(kProjectId, 'i3'));
      await tapVisible(tester, find.text('Kalemi İptal Et'));
      await tester.tap(find.text('İptal Et'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Bu işlem için yetkin yok.'), findsOneWidget);
    });

    testWidgets('bilinmeyen kalem: bulunamadı mesajı', (tester) async {
      await pumpApp(
        tester,
        user: fpOwnerUser,
        repo: FakeFinancePlanRepository(),
        location: paymentPlanItemPath(kProjectId, 'yok'),
      );
      expect(find.text('Ödeme planı kalemi bulunamadı.'), findsOneWidget);
    });
  });

  group('Faturalar', () {
    testWidgets('izin yoksa API çağrılmaz', (tester) async {
      final repo = FakeFinancePlanRepository();
      await pumpApp(tester, user: fpNoAccessUser, repo: repo, location: invoicesListPath);
      expect(find.byType(NoAccessView), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('liste: vadesi geçen satış faturası uyarısı ve tür süzgeci', (tester) async {
      await pumpApp(tester, user: fpOwnerUser, repo: FakeFinancePlanRepository(), location: invoicesListPath);
      expect(find.text('1 satış faturasının vadesi geçti'), findsOneWidget);
      expect(find.text('Vadesi geçti · 19.09.2026'), findsOneWidget);
      // Alış faturası vadesi geçse de uyarı sayılmaz (ana sayfa kuralı).
      expect(find.text('Vade 10.09.2026'), findsOneWidget);
      expect(find.text('Fatura Ekle'), findsOneWidget);

      await tester.tap(find.text('Satış (4)'));
      await tester.pumpAndSettle();
      expect(find.text('ALS-88412'), findsNothing);
      expect(find.text('ARV2026000145'), findsOneWidget);
    });

    testWidgets('salt-okunur: ekleme yok, detayda durum aksiyonu yok', (tester) async {
      await pumpApp(tester, user: fpReadOnlyUser, repo: FakeFinancePlanRepository(), location: invoicesListPath);
      expect(find.text('Fatura Ekle'), findsNothing);
      await tester.tap(find.text('ARV2026000131'));
      await tester.pumpAndSettle();
      expect(find.text('375.000,00 TL'), findsOneWidget);
      expect(find.text('Durumu Değiştir'), findsNothing);
      expect(find.text('Faturayı İptal Et'), findsNothing);
    });

    testWidgets('vadesi geçmiş satış faturası: birincil aksiyon doğrudan Ödendi (şeridin önerdiği adım)', (tester) async {
      // Regresyon: şerit "Ödendi yap" derken birincil düğme "Gönderildi
      // Olarak İşaretle"ydi.
      final repo = FakeFinancePlanRepository();
      await pumpApp(tester, user: fpManagerUser, repo: repo, location: invoicePath(kProjectId, 'f3'));
      expect(find.text('Gönderildi Olarak İşaretle'), findsNothing);
      await tapVisible(tester, find.text('Ödendi Olarak İşaretle'));
      expect(find.textContaining('"Ödendi" olarak değiştirilsin mi?'), findsOneWidget);
      await tester.tap(find.text('Değiştir'));
      await tester.pumpAndSettle();
      expect(repo.statusChanges, [('f3', kInvoicePaid)]);
      expect(find.textContaining('Olarak İşaretle'), findsNothing);
    });

    testWidgets('alış faturası: "Gönderildi" adımı yok, Kesildi -> Ödendi; karşı taraf Tedarikçi', (tester) async {
      await pumpApp(tester, user: fpManagerUser, repo: FakeFinancePlanRepository(), location: invoicePath(kProjectId, 'f2'));
      expect(find.text('Gönderildi Olarak İşaretle'), findsNothing);
      expect(find.text('Ödendi Olarak İşaretle'), findsOneWidget);
      expect(find.text('Tedarikçi / Firma'), findsOneWidget);
      expect(find.text('Müşteri / Firma'), findsNothing);
    });

    testWidgets('durum seçicisi her durumu bir kez yazar, İptal içermez (ayrı kırmızı düğme var)', (tester) async {
      await pumpApp(tester, user: fpManagerUser, repo: FakeFinancePlanRepository(), location: invoicePath(kProjectId, 'f1'));
      await tapVisible(tester, find.text('Durumu Değiştir'));
      final sheet = find.byType(BottomSheet);
      expect(find.descendant(of: sheet, matching: find.text('Kesildi')), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('Gönderildi')), findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.text('İptal')), findsNothing);
      expect(find.descendant(of: sheet, matching: find.byType(StatusBadge)), findsNothing);
    });

    testWidgets('"Durumu Değiştir" ile herhangi bir durum seçilebilir (web ile aynı)', (tester) async {
      final repo = FakeFinancePlanRepository();
      await pumpApp(tester, user: fpOwnerUser, repo: repo, location: invoicePath(kProjectId, 'f4'));
      // Ödendi faturada birincil adım yok.
      expect(find.textContaining('Olarak İşaretle'), findsNothing);
      await tapVisible(tester, find.text('Durumu Değiştir'));
      await tester.tap(find.widgetWithText(ListTile, 'Kesildi').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Değiştir'));
      await tester.pumpAndSettle();
      expect(repo.statusChanges, [('f4', kInvoiceIssued)]);
    });

    testWidgets('iptal onaylı ve kırmızı; iptal edilen faturada iptal aksiyonu kalkar', (tester) async {
      final repo = FakeFinancePlanRepository();
      await pumpApp(tester, user: fpOwnerUser, repo: repo, location: invoicePath(kProjectId, 'f1'));
      await tapVisible(tester, find.text('Faturayı İptal Et'));
      expect(find.textContaining('kesilen fatura toplamına dahil edilmez'), findsOneWidget);
      await tester.tap(find.text('İptal Et'));
      await tester.pumpAndSettle();
      expect(repo.statusChanges, [('f1', kInvoiceCancelled)]);
      expect(find.text('Faturayı İptal Et'), findsNothing);
    });

    testWidgets('kilitli projede durum değiştirilemez', (tester) async {
      await pumpApp(
        tester,
        user: fpOwnerUser,
        repo: FakeFinancePlanRepository(),
        location: invoicePath(kProjectId, 'f1'),
        project: () => financeProject(status: 'cancelled'),
      );
      expect(find.text('Durumu Değiştir'), findsNothing);
      expect(find.text(kProjectLockedNoticeText), findsOneWidget);
    });

    testWidgets('yeni fatura: doğrulama, Alış seçimi, taslak + proje para birimi', (tester) async {
      final repo = FakeFinancePlanRepository();
      await pumpApp(tester, user: fpManagerUser, repo: repo, location: invoicesListPath);
      await tester.tap(find.text('Fatura Ekle'));
      await tester.pumpAndSettle();

      await tapVisible(tester, find.text('Faturayı Kaydet'));
      expect(find.text('Fatura numarası zorunludur'), findsOneWidget);
      expect(find.text('Tutar sıfırdan büyük olmalıdır'), findsOneWidget);

      await tester.tap(find.text('Alış'));
      await tester.enterText(find.byKey(const ValueKey('invoice-no')), 'ALS-90001');
      await tester.enterText(find.byKey(const ValueKey('invoice-amount')), '12500');
      // Alışta karşı taraf tedarikçidir ve zorunludur: boş bırakılırsa backend
      // proje MÜŞTERİSİNİ yazardı.
      expect(find.text('Tedarikçi / Firma *'), findsOneWidget);
      expect(find.textContaining('Boş bırakılırsa proje müşterisi'), findsNothing);
      await tapVisible(tester, find.text('Faturayı Kaydet'));
      expect(find.text('Tedarikçi adı zorunludur'), findsOneWidget);
      expect(repo.createdInvoices, isEmpty);
      await tester.enterText(find.byKey(const ValueKey('invoice-customer')), 'Kaya Yapı Malzemeleri');
      await tapVisible(tester, find.text('Faturayı Kaydet'));

      final input = repo.createdInvoices.single;
      expect(input.customerName, 'Kaya Yapı Malzemeleri');
      expect(input.invoiceNo, 'ALS-90001');
      expect(input.invoiceType, kInvoiceTypePurchase);
      expect(input.invoiceDate, '2026-09-29');
      expect(input.amount, 12500);
      expect(input.currency, 'TRY');
      expect(input.toJson()['status'], 'draft');
      expect(find.text('"ALS-90001" faturası eklendi.'), findsOneWidget);
      expect(find.text('ALS-90001'), findsOneWidget);
    });

    testWidgets('kayıt sürerken çıkış engellenir', (tester) async {
      final repo = FakeFinancePlanRepository()..writeGate = Completer<void>();
      await pumpApp(tester, user: fpOwnerUser, repo: repo, location: invoicesListPath);
      await tester.tap(find.text('Fatura Ekle'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('invoice-no')), 'ARV-1');
      await tester.enterText(find.byKey(const ValueKey('invoice-amount')), '10');
      await tester.scrollUntilVisible(find.text('Faturayı Kaydet'), 200, scrollable: find.byType(Scrollable).last);
      await tester.tap(find.text('Faturayı Kaydet'));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('Kaydediliyor, lütfen bitmesini bekle.'), findsOneWidget);
      repo.writeGate!.complete();
      await tester.pumpAndSettle();
      expect(repo.createdInvoices, hasLength(1));
    });
  });
}
