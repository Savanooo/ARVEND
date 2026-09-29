import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/budget/budget_routes.dart';
import 'package:arvend/features/projects/budget/presentation/widgets/budget_ui.dart';
import 'package:arvend/features/projects/budget/presentation/widgets/cost_line_widgets.dart';
import 'package:arvend/features/projects/domain/project.dart';

import 'budget_test_support.dart';

/// Bütçe & Maliyet Kontrolü ekran davranışları: izin kapıları (router.go
/// kodlarıyla), 403'te çökmeme, akışlar (oluştur/baseline/kalem/revizyon/
/// WBS/taahhüt/tahmin) ve 409'da ekranın sunucudaki güncel duruma dönmesi.
void main() {
  Future<FakeBudgetRepository> pump(
    WidgetTester tester, {
    required User user,
    String? location,
    FakeBudgetRepository? repo,
    Project? project,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 2400);
    addTearDown(tester.view.reset);
    final r = repo ?? FakeBudgetRepository();
    await tester.pumpWidget(buildBudgetApp(user: user, repo: r, project: project, initialLocation: location));
    await tester.pumpAndSettle();
    return r;
  }

  Finder inDialog(String text) => find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

  /// Açılır listedeki öğe (WBS öğeleri girintili yazıldığı için içerir-eşleşme).
  Future<void> selectDropdown(WidgetTester tester, String key, String item) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(item).last);
    await tester.pumpAndSettle();
  }

  const writeLabels = [
    'Kalem Ekle',
    'Baseline Al',
    'Düzenle',
    'Sil',
    'Revize Et',
    'Bütçe Oluştur',
    'Revizyon Oluştur',
    'Onayla',
    'Reddet',
    'Manuel Taahhüt',
    'Manuel ETC Gir',
    'Kök Düğüm Ekle',
    'Taahhüdü İptal Et',
    'ETC Düzenle',
  ];

  void expectNoWriteActions() {
    for (final label in writeLabels) {
      expect(find.text(label), findsNothing, reason: '"$label" izinsiz kullanıcıya görünmemeli');
    }
  }

  group('İzinler', () {
    testWidgets('Proje Yöneticisi (budget+cost_control, finans YOK): gelir/kâr/marj görünmez, maliyet görünür', (
      tester,
    ) async {
      // Regresyon: özet kartı sözleşme bedelini, tahmini kârı ve marjı finans
      // izni olmayan varsayılan Proje Yöneticisi rolüne gösteriyordu.
      await pump(tester, user: budgetReadOnlyUser);
      expect(find.text('Sözleşme Bedeli'), findsNothing);
      expect(find.text('Tahmini Kâr'), findsNothing);
      expect(find.text('Tahmini Marj'), findsNothing);
      // Maliyet rakamları rol tasarımı gereği görünür (migration 0035).
      expect(find.text('Revize Bütçe'), findsOneWidget);
      expect(find.text('Tahmini Nihai Maliyet (EAC)'), findsOneWidget);
    });

    testWidgets('finans izniyle gelir/kâr/marj görünür', (tester) async {
      await pump(tester, user: budgetOwnerUser);
      expect(find.text('Sözleşme Bedeli'), findsOneWidget);
      expect(find.text('Tahmini Kâr'), findsOneWidget);
      expect(find.text('Tahmini Marj'), findsOneWidget);
    });

    testWidgets('bütçesiz projede Proje Yöneticisi: sözleşme bedeli yok, oluşturma yönlendirmesi yok', (tester) async {
      await pump(
        tester,
        user: budgetReadOnlyUser,
        repo: FakeBudgetRepository(budget: null, adjustments: const [], commitments: const [], costControl: emptyCostControl()),
      );
      expect(find.text('Henüz bütçe yok'), findsOneWidget);
      expect(find.text('Sözleşme Bedeli'), findsNothing);
      expect(find.text('Bütçe Oluştur'), findsNothing);
      expect(find.textContaining('başlayabilirsin'), findsNothing);
      expect(find.textContaining('izni olan biri oluşturabilir'), findsOneWidget);
      expect(find.text('Bütçe dışı taahhüt'), findsOneWidget);
    });

    testWidgets('saha: sekme yetkisiz görünüm, hiçbir istek atılmaz, para görünmez', (tester) async {
      final repo = await pump(tester, user: budgetFieldUser);
      expect(find.text('Yetkin yok'), findsOneWidget);
      expect(find.text(kBudgetModuleNoAccessText), findsOneWidget);
      expect(repo.calls, isEmpty);
      expect(find.textContaining('TL'), findsNothing);
    });

    testWidgets('saha: alt ekranlara derin bağlantıyla da giremez', (tester) async {
      for (final path in [
        costControlPath(kProjectId),
        budgetPath(kProjectId),
        budgetLineCreatePath(kProjectId),
        wbsPath(kProjectId),
        budgetAdjustmentsPath(kProjectId),
        commitmentsPath(kProjectId),
        commitmentCreatePath(kProjectId),
        forecastPath(kProjectId),
        actualCostPath(kProjectId),
      ]) {
        final repo = await pump(tester, user: budgetFieldUser, location: path);
        expect(find.text('Yetkin yok'), findsWidgets, reason: path);
        expect(repo.calls, isEmpty, reason: path);
        expect(find.textContaining(' TL'), findsNothing, reason: path);
      }
    });

    testWidgets('proje yöneticisi (salt okunur): sekmede ve satır dökümünde yazma aksiyonu yok', (tester) async {
      final repo = await pump(tester, user: budgetReadOnlyUser);
      expect(find.text('Maliyet Özeti'), findsOneWidget);
      expect(find.text('Taahhütler'), findsOneWidget);
      // Finans okuma izni yok -> masraf kırılımı kartı yok, masraf istenmez.
      expect(find.text('Gerçekleşen'), findsWidgets); // özet satırı
      expect(find.text('Maliyet koduna göre masraflar'), findsNothing);
      expect(repo.count('expenses'), 0);
      await tester.tap(find.text('MLZ-002 — İnşaat Demiri'));
      await tester.pumpAndSettle();
      expect(find.text('Revize Bütçe'), findsWidgets);
      expectNoWriteActions();
    });

    testWidgets('proje yöneticisi: bütçe, WBS, revizyon, taahhüt, tahmin ekranları salt okunur', (tester) async {
      await pump(tester, user: budgetReadOnlyUser, location: budgetPath(kProjectId));
      expect(find.text(kBudgetReadOnlyText), findsOneWidget);
      expect(find.text('Karkas donatısı'), findsOneWidget);
      expectNoWriteActions();

      await pump(tester, user: budgetReadOnlyUser, location: wbsPath(kProjectId));
      expect(find.text(kWbsReadOnlyText), findsOneWidget);
      expect(find.byTooltip('Düğüm işlemleri'), findsNothing);
      expectNoWriteActions();

      await pump(tester, user: budgetReadOnlyUser, location: budgetAdjustmentsPath(kProjectId));
      expect(find.text('Taslak'), findsNWidgets(2));
      expectNoWriteActions();

      await pump(tester, user: budgetReadOnlyUser, location: commitmentsPath(kProjectId));
      expect(find.text(kCostControlReadOnlyText), findsOneWidget);
      expectNoWriteActions();
      await tester.tap(find.text('Şantiye güvenlik hizmeti (Ekim)'));
      await tester.pumpAndSettle();
      expect(find.text('Taahhüdü İptal Et'), findsNothing);

      await pump(tester, user: budgetReadOnlyUser, location: forecastPath(kProjectId));
      expect(find.text('Kalan döküm 17 m³', findRichText: true), findsNothing);
      expect(find.textContaining('Kalan döküm'), findsOneWidget);
      expectNoWriteActions();
    });

    testWidgets('proje yöneticisi: formlara derin bağlantı yetkisiz görünüm, istek yok', (tester) async {
      for (final path in [budgetLineCreatePath(kProjectId), commitmentCreatePath(kProjectId)]) {
        final repo = await pump(tester, user: budgetReadOnlyUser, location: path);
        expect(find.text('Yetkin yok'), findsOneWidget, reason: path);
        expect(repo.calls.where((c) => c.startsWith('create')), isEmpty);
      }
    });

    testWidgets('yalnızca bütçe izni: maliyet kontrolü uçları hiç istenmez', (tester) async {
      final repo = await pump(tester, user: budgetOnlyUser);
      expect(repo.count('costControl'), 0);
      expect(repo.count('commitments'), 0);
      expect(repo.count('forecasts'), 0);
      expect(find.textContaining('Maliyet özetini görmek için'), findsOneWidget);
      expect(find.text('Bütçe'), findsOneWidget);
      expect(find.text('Taahhütler'), findsNothing);
      expect(find.text('Tahmin (ETC)'), findsNothing);
    });

    testWidgets('tamamlanan proje: sahipte bile yazma aksiyonu yok, kilit notu görünür', (tester) async {
      final locked = sampleProject(status: 'completed');
      await pump(tester, user: budgetOwnerUser, project: locked);
      expect(find.text(kProjectLockedText), findsOneWidget);
      await tester.tap(find.text('MLZ-002 — İnşaat Demiri'));
      await tester.pumpAndSettle();
      expectNoWriteActions();

      for (final path in [
        budgetPath(kProjectId),
        wbsPath(kProjectId),
        budgetAdjustmentsPath(kProjectId),
        commitmentsPath(kProjectId),
        forecastPath(kProjectId),
      ]) {
        await pump(tester, user: budgetOwnerUser, project: locked, location: path);
        expect(find.text(kProjectLockedText), findsOneWidget, reason: path);
        expectNoWriteActions();
      }

      await pump(
        tester,
        user: budgetOwnerUser,
        project: locked,
        location: budgetLineCreatePath(kProjectId),
        repo: FakeBudgetRepository(budget: kDraftBudget),
      );
      expect(find.text(kProjectLockedText), findsOneWidget);
      expect(find.text('Kaydet'), findsNothing);
    });

    testWidgets('sunucu 403: sekme ve ekranlar çökmez, yetki notu gösterir', (tester) async {
      final repo = FakeBudgetRepository()..errors['costControl'] = forbidden;
      await pump(tester, user: budgetOwnerUser, repo: repo);
      expect(tester.takeException(), isNull);
      expect(find.text(kCostControlNoAccessText), findsOneWidget);
      // Bütçe tarafı yine çalışır.
      expect(find.text('Bütçe'), findsOneWidget);

      final repo2 = FakeBudgetRepository()..errors['budget'] = forbidden;
      await pump(tester, user: budgetOwnerUser, repo: repo2, location: budgetPath(kProjectId));
      expect(tester.takeException(), isNull);
      expect(find.text('Yetkin yok'), findsOneWidget);

      final repo3 = FakeBudgetRepository()..errors['commitments'] = forbidden;
      await pump(tester, user: budgetOwnerUser, repo: repo3, location: commitmentsPath(kProjectId));
      expect(find.text('Yetkin yok'), findsOneWidget);
    });
  });

  group('Maliyet Kontrolü sekmesi', () {
    testWidgets('bütçe aşımı vurgusu ve "Aşanlar" süzmesi', (tester) async {
      await pump(tester, user: budgetOwnerUser);
      expect(find.textContaining('revize bütçeyi 289.000,00 TL aşıyor'), findsOneWidget);
      expect(find.text('Bütçe aşımı'), findsOneWidget);
      expect(find.byType(CostLineCard), findsNWidgets(7));
      await tester.tap(find.byKey(const ValueKey('cost-lines-over-only')));
      await tester.pumpAndSettle();
      expect(find.byType(CostLineCard), findsNWidgets(3));
      expect(find.text('ISC-001 — Kalıp İşçiliği'), findsNothing);
      expect(find.text('MLZ-004 — Alçı Sıva'), findsOneWidget);
    });

    testWidgets('bütçesiz proje: "Bütçe Oluştur" bütçeyi oluşturur ve Bütçe ekranını açar', (tester) async {
      final repo = FakeBudgetRepository(budget: null, adjustments: const [], costControl: emptyCostControl());
      await pump(tester, user: budgetOwnerUser, repo: repo);
      expect(find.text('Henüz bütçe yok'), findsOneWidget);
      await tester.tap(find.text('Bütçe Oluştur'));
      await tester.pumpAndSettle();
      expect(repo.count('createBudget'), 1);
      expect(find.text('Taslak — kalemler serbestçe düzenlenebilir.'), findsOneWidget);
    });

    testWidgets('satır dökümü -> Manuel ETC Gir -> tahmin kaydedilir', (tester) async {
      final repo = await pump(tester, user: budgetOwnerUser);
      await tester.tap(find.text('ISC-001 — Kalıp İşçiliği'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manuel ETC Gir'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('forecast-etc')), '650.000');
      await tester.enterText(find.byKey(const ValueKey('forecast-note')), 'İki kat kaldı');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(repo.forecastInputs.single, (lineId: 'l3', etc: 650000.0, note: 'İki kat kaldı'));
      expect(find.text('ETC tahmini kaydedildi.'), findsOneWidget);
      // Yazma sonrası özet yeniden istenir.
      expect(repo.count('costControl'), greaterThanOrEqualTo(2));
    });

    testWidgets('satır dökümü -> Revize Et -> kaleme sabit revizyon taslağı', (tester) async {
      final repo = await pump(tester, user: budgetFinanceUser);
      await tester.tap(find.text('EKP-001 — Kule Vinç Kirası'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revize Et'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('adjustment-line')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('adjustment-amount')), '145.000');
      await tester.enterText(find.byKey(const ValueKey('adjustment-reason')), 'Kira uzadı');
      await tester.tap(find.text('Revizyon Oluştur'));
      await tester.pumpAndSettle();
      expect(repo.adjustmentInputs.single, (lineId: 'l5', amount: 145000.0, reason: 'Kira uzadı'));
    });

    testWidgets('bütçe dışı satırda ETC/revizyon aksiyonu yok (bütçe kalemi yok)', (tester) async {
      await pump(tester, user: budgetOwnerUser);
      await tester.tap(find.text('MLZ-004 — Alçı Sıva'));
      await tester.pumpAndSettle();
      expect(find.textContaining('bütçe kalemi yok'), findsOneWidget);
      expect(find.text('Manuel ETC Gir'), findsNothing);
      expect(find.text('Revize Et'), findsNothing);
    });
  });

  group('Bütçe', () {
    testWidgets('bütçe yok -> Bütçe Oluştur -> taslak', (tester) async {
      final repo = await pump(
        tester,
        user: budgetOwnerUser,
        location: budgetPath(kProjectId),
        repo: FakeBudgetRepository(budget: null),
      );
      expect(find.text('Bu proje için henüz bir bütçe yok'), findsOneWidget);
      await tester.tap(find.text('Bütçe Oluştur'));
      await tester.pumpAndSettle();
      expect(repo.count('createBudget'), 1);
      expect(find.text('Kalem Ekle'), findsOneWidget);
      expect(find.text('Bütçe oluşturuldu.'), findsOneWidget);
    });

    testWidgets('Baseline Al: onay penceresi; Vazgeç istek atmaz, onay tek yönlü geçişi yapar', (tester) async {
      final repo = await pump(
        tester,
        user: budgetOwnerUser,
        location: budgetPath(kProjectId),
        repo: FakeBudgetRepository(budget: kDraftBudget, adjustments: const []),
      );
      await tester.tap(find.text('Baseline Al'));
      await tester.pumpAndSettle();
      expect(find.textContaining('GERİ ALINAMAZ'), findsOneWidget);
      await tester.tap(inDialog('Vazgeç'));
      await tester.pumpAndSettle();
      expect(repo.count('baselineBudget'), 0);

      await tester.tap(find.text('Baseline Al'));
      await tester.pumpAndSettle();
      await tester.tap(inDialog('Baseline Al'));
      await tester.pumpAndSettle();
      expect(repo.count('baselineBudget'), 1);
      expect(find.text('Baseline Alındı'), findsOneWidget);
      expect(find.text('Revize Et'), findsNWidgets(kBudgetLines.length));
      expect(find.text('Düzenle'), findsNothing);
    });

    testWidgets('Baseline 409: backend mesajı gösterilir, ekran sunucudan tazelenir', (tester) async {
      final repo = FakeBudgetRepository(budget: kDraftBudget)
        ..errors['baselineBudget'] = conflict('yalnızca taslak durumundaki bir bütçe baseline alınabilir');
      await pump(tester, user: budgetOwnerUser, location: budgetPath(kProjectId), repo: repo);
      final before = repo.count('budget');
      // Başka biri bu arada baseline aldı.
      repo.budgetValue = kBaselinedBudget;
      await tester.tap(find.text('Baseline Al'));
      await tester.pumpAndSettle();
      await tester.tap(inDialog('Baseline Al'));
      await tester.pumpAndSettle();
      expect(find.text('yalnızca taslak durumundaki bir bütçe baseline alınabilir'), findsOneWidget);
      expect(repo.count('budget'), greaterThan(before));
      expect(find.text('Baseline Alındı'), findsOneWidget);
    });

    testWidgets('kalem ekle: Türkçe ondalıklar, miktar×birim fiyatta tutar kilitlenir', (tester) async {
      final repo = await pump(
        tester,
        user: budgetOwnerUser,
        location: budgetPath(kProjectId),
        repo: FakeBudgetRepository(budget: kDraftBudget),
      );
      await tester.tap(find.text('Kalem Ekle'));
      await tester.pumpAndSettle();
      expect(find.text('Yeni Bütçe Kalemi'), findsOneWidget);

      // Boş gönderim: doğrulama, istek yok.
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Maliyet kodu seç'), findsOneWidget);
      expect(find.text('Bütçe kalemi açıklaması zorunludur'), findsOneWidget);
      expect(repo.count('createBudgetLine'), 0);

      // Arşivlenmiş maliyet kodu seçilemez.
      await tester.tap(find.byKey(const ValueKey('line-cost-code')));
      await tester.pumpAndSettle();
      expect(find.text('MLZ-003 — Tuğla'), findsNothing);
      await tester.tap(find.text('MLZ-001 — Hazır Beton').last);
      await tester.pumpAndSettle();
      await selectDropdown(tester, 'line-wbs', '01.01 — Temel');
      await tester.enterText(find.byKey(const ValueKey('line-description')), 'Grobeton');
      await tester.enterText(find.byKey(const ValueKey('line-quantity')), '12,5');
      await tester.enterText(find.byKey(const ValueKey('line-unit')), 'm³');
      await tester.enterText(find.byKey(const ValueKey('line-unit-cost')), '1.250,50');
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(find.byKey(const ValueKey('line-amount'))).enabled, isFalse);
      expect(find.textContaining('sunucuda otomatik hesaplanır'), findsOneWidget);
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();

      final input = repo.lineInputs.single;
      expect(input.costCodeId, 'cc-mlz1');
      expect(input.wbsNodeId, 'w2');
      expect(input.description, 'Grobeton');
      expect(input.quantity, 12.5);
      expect(input.unitCost, 1250.5);
      expect(input.unit, 'm³');
      expect(find.text('Bütçe kalemi kaydedildi.'), findsOneWidget);
      expect(find.text('Yeni Bütçe Kalemi'), findsNothing);
    });

    testWidgets('kalem ekle: geçersiz sayı ve 2+ ondalık reddedilir', (tester) async {
      final repo = await pump(
        tester,
        user: budgetOwnerUser,
        location: budgetLineCreatePath(kProjectId),
        repo: FakeBudgetRepository(budget: kDraftBudget),
      );
      await tester.enterText(find.byKey(const ValueKey('line-quantity')), '1,2,3');
      await tester.enterText(find.byKey(const ValueKey('line-amount')), '10,555');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Geçerli bir sayı gir'), findsOneWidget);
      expect(find.text('En fazla 2 ondalık basamak girilebilir.'), findsOneWidget);
      expect(repo.count('createBudgetLine'), 0);
    });

    testWidgets('kalem düzenle: alanlar dolu gelir, notlar korunur', (tester) async {
      final repo = await pump(
        tester,
        user: budgetOwnerUser,
        location: budgetPath(kProjectId),
        repo: FakeBudgetRepository(budget: kDraftBudget),
      );
      await tester.tap(find.text('Düzenle').at(2)); // l3: notlu, miktarsız kalem
      await tester.pumpAndSettle();
      expect(find.text('Bütçe Kalemini Düzenle'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Karkas kalıp işçiliği'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '1850000'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('line-amount')), '1.900.000');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(repo.count('updateBudgetLine'), 1);
      expect(repo.calls, contains('updateBudgetLine:l3'));
      final input = repo.lineInputs.single;
      expect(input.originalAmount, 1900000);
      expect(input.notes, 'Götürü bedel, 12 kat');
      expect(input.costCodeId, 'cc-isc1');
      expect(input.wbsNodeId, 'w3');
    });

    testWidgets('kalem düzenle 409 (bu arada baseline alındı): mesaj + form kilitlenir', (tester) async {
      final repo = FakeBudgetRepository(budget: kDraftBudget);
      await pump(tester, user: budgetOwnerUser, location: budgetLineEditPath(kProjectId, 'l1'), repo: repo);
      repo
        ..budgetValue = kBaselinedBudget
        ..errors['updateBudgetLine'] = conflict(
          'baseline alınmış bir bütçenin kalemleri yalnızca bütçe revizyonu (adjustment) ile değiştirilebilir',
        );
      await tester.enterText(find.byKey(const ValueKey('line-description')), 'Temel betonu (revize)');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.textContaining('yalnızca bütçe revizyonu (adjustment) ile'), findsOneWidget);
      expect(find.textContaining('Bütçe baseline alındı —'), findsOneWidget);
      expect(find.text('Kaydet'), findsNothing);
    });

    testWidgets('kalem sil: onaydan sonra DELETE', (tester) async {
      final repo = await pump(
        tester,
        user: budgetOwnerUser,
        location: budgetPath(kProjectId),
        repo: FakeBudgetRepository(budget: kDraftBudget),
      );
      await tester.tap(find.text('Sil').first);
      await tester.pumpAndSettle();
      expect(find.text('"Temel betonu C30/37" kalemi silinecek.'), findsOneWidget);
      await tester.tap(inDialog('Sil'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('deleteBudgetLine:l1'));
      expect(find.text('Temel betonu C30/37'), findsNothing);
    });
  });

  group('Bütçe Revizyonları', () {
    testWidgets('bütçe ekranından Revize Et: sıfır reddedilir, negatif tutar gönderilir', (tester) async {
      final repo = await pump(tester, user: budgetOwnerUser, location: budgetPath(kProjectId));
      await tester.tap(find.text('Revize Et').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('adjustment-amount')), '0');
      await tester.enterText(find.byKey(const ValueKey('adjustment-reason')), 'Test');
      await tester.tap(find.text('Revizyon Oluştur'));
      await tester.pumpAndSettle();
      expect(find.text('Revizyon tutarı sıfır olamaz'), findsOneWidget);
      expect(repo.count('createAdjustment'), 0);

      await tester.enterText(find.byKey(const ValueKey('adjustment-amount')), '-25.000');
      await tester.tap(find.text('Revizyon Oluştur'));
      await tester.pumpAndSettle();
      expect(repo.adjustmentInputs.single, (lineId: 'l1', amount: -25000.0, reason: 'Test'));
      expect(find.textContaining('Revizyon oluşturuldu'), findsOneWidget);
    });

    testWidgets('revizyonlar ekranından oluştur: kalem seçimi zorunlu', (tester) async {
      final repo = await pump(tester, user: budgetOwnerUser, location: budgetAdjustmentsPath(kProjectId));
      await tester.tap(find.text('Revizyon Oluştur'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('adjustment-amount')), '12.000,50');
      await tester.enterText(find.byKey(const ValueKey('adjustment-reason')), 'Ek iş');
      await tester.tap(find.text('Revizyon Oluştur').last);
      await tester.pumpAndSettle();
      expect(find.text('Bütçe kalemi seç'), findsOneWidget);
      await selectDropdown(tester, 'adjustment-line', 'Karkas donatısı (MLZ-002)');
      await tester.tap(find.text('Revizyon Oluştur').last);
      await tester.pumpAndSettle();
      expect(repo.adjustmentInputs.single, (lineId: 'l2', amount: 12000.5, reason: 'Ek iş'));
    });

    testWidgets('Onayla: onay penceresinden sonra approve; karar verilen revizyonda buton kalmaz', (tester) async {
      final repo = await pump(tester, user: budgetOwnerUser, location: budgetAdjustmentsPath(kProjectId));
      expect(find.text('Onayla'), findsNWidgets(2));
      await tester.tap(find.text('Onayla').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('"Karkas kalıp işçiliği" kalemi için +120.000,00 TL'), findsOneWidget);
      await tester.tap(inDialog('Onayla'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('approveAdjustment:a4'));
      expect(find.text('Revizyon onaylandı.'), findsOneWidget);
      expect(find.text('Onayla'), findsOneWidget);
    });

    testWidgets('Reddet 409 (başkası karara bağladı): mesaj + liste tazelenir', (tester) async {
      final repo = FakeBudgetRepository()
        ..errors['rejectAdjustment'] = conflict(
          'yalnızca taslak durumundaki bir bütçe revizyonu onaylanabilir veya reddedilebilir',
        );
      await pump(tester, user: budgetOwnerUser, location: budgetAdjustmentsPath(kProjectId), repo: repo);
      final before = repo.count('adjustments');
      await tester.tap(find.text('Reddet').first);
      await tester.pumpAndSettle();
      await tester.tap(inDialog('Reddet'));
      await tester.pumpAndSettle();
      expect(find.textContaining('yalnızca taslak durumundaki bir bütçe revizyonu'), findsOneWidget);
      expect(repo.count('adjustments'), greaterThan(before));
    });

    testWidgets('taslak bütçede revizyon oluşturulamaz', (tester) async {
      await pump(
        tester,
        user: budgetOwnerUser,
        location: budgetAdjustmentsPath(kProjectId),
        repo: FakeBudgetRepository(budget: kDraftBudget, adjustments: const []),
      );
      expect(find.textContaining('yalnızca baseline alınmış bir bütçe için'), findsOneWidget);
      expect(find.text('Revizyon Oluştur'), findsNothing);
    });
  });

  group('WBS', () {
    testWidgets('kök düğüm ekle', (tester) async {
      final repo = await pump(tester, user: budgetOwnerUser, location: wbsPath(kProjectId));
      await tester.tap(find.text('Kök Düğüm Ekle'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('wbs-code')), '04');
      await tester.enterText(find.byKey(const ValueKey('wbs-name')), 'Peyzaj');
      await tester.tap(find.text('Ekle'));
      await tester.pumpAndSettle();
      expect(repo.wbsInputs.single.toJson(), {'parent_id': '', 'code': '04', 'name': 'Peyzaj', 'sort_order': 0});
      expect(find.text('WBS düğümü eklendi.'), findsOneWidget);
    });

    testWidgets('alt düğüm ekle: üst düğüm gönderilir; arşivli düğümde işlem menüsü yok', (tester) async {
      final repo = await pump(tester, user: budgetOwnerUser, location: wbsPath(kProjectId));
      // 7 düğümden 1'i arşivli.
      expect(find.byTooltip('Düğüm işlemleri'), findsNWidgets(6));
      await tester.tap(find.byTooltip('Düğüm işlemleri').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alt Düğüm Ekle'));
      await tester.pumpAndSettle();
      expect(find.text('Üst düğüm: 01 — Kaba İnşaat'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('wbs-code')), '01.03');
      await tester.enterText(find.byKey(const ValueKey('wbs-name')), 'Çatı');
      await tester.tap(find.text('Ekle'));
      await tester.pumpAndSettle();
      expect(repo.wbsInputs.single.parentId, 'w1');
    });

    testWidgets('yeniden adlandır: sıra korunur', (tester) async {
      final repo = await pump(tester, user: budgetOwnerUser, location: wbsPath(kProjectId));
      await tester.tap(find.byTooltip('Düğüm işlemleri').at(2)); // 01.02
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yeniden Adlandır'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, 'Betonarme Karkas'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('wbs-name')), 'Betonarme Karkas (A)');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('updateWbsNode:w3'));
      expect(repo.wbsInputs.single.sortOrder, 2);
      expect(find.textContaining('Betonarme Karkas (A)', findRichText: true), findsOneWidget);
    });

    testWidgets('arşivle: onaydan sonra DELETE, düğüm "Arşivlendi" olur', (tester) async {
      final repo = await pump(tester, user: budgetOwnerUser, location: wbsPath(kProjectId));
      await tester.tap(find.byTooltip('Düğüm işlemleri').last); // 03
      await tester.pumpAndSettle();
      await tester.tap(find.text('Arşivle'));
      await tester.pumpAndSettle();
      expect(find.textContaining('bağlı bütçe kalemleri etkilenmez'), findsOneWidget);
      await tester.tap(inDialog('Arşivle'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('archiveWbsNode:w7'));
      expect(find.text('Arşivlendi'), findsNWidgets(2));
    });

    testWidgets('mükerrer kod 409: mesaj sayfada kalır', (tester) async {
      final repo = FakeBudgetRepository()
        ..errors['createWbsNode'] = conflict('bu WBS kodu bu projede zaten kullanılıyor');
      await pump(tester, user: budgetOwnerUser, location: wbsPath(kProjectId), repo: repo);
      await tester.tap(find.text('Kök Düğüm Ekle'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('wbs-code')), '01');
      await tester.enterText(find.byKey(const ValueKey('wbs-name')), 'Tekrar');
      await tester.tap(find.text('Ekle'));
      await tester.pumpAndSettle();
      expect(find.text('bu WBS kodu bu projede zaten kullanılıyor'), findsOneWidget);
      expect(find.byKey(const ValueKey('wbs-code')), findsOneWidget);
    });
  });

  group('Taahhütler', () {
    testWidgets('manuel taahhüt: bütçe kalemi seçilince maliyet kodu o kalemden gelir', (tester) async {
      final repo = await pump(tester, user: budgetOwnerUser, location: commitmentsPath(kProjectId));
      await tester.tap(find.text('Manuel Taahhüt'));
      await tester.pumpAndSettle();
      expect(find.text('Yeni Manuel Taahhüt'), findsOneWidget);
      await selectDropdown(tester, 'commitment-line', 'Şantiye genel giderleri (GNL-001)');
      expect(find.byKey(const ValueKey('commitment-cost-code')), findsNothing);
      expect(find.text('GNL-001 — Şantiye Genel Giderleri'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('commitment-description')), 'Temizlik hizmeti');
      await tester.enterText(find.byKey(const ValueKey('commitment-amount')), '1.500,75');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      final input = repo.commitmentInputs.single;
      expect(input.costCodeId, 'cc-gnl1');
      expect(input.budgetLineId, 'l6');
      expect(input.amount, 1500.75);
      expect(input.committedAt, '2026-09-29');
      expect(input.idempotencyKey, hasLength(32));
      expect(find.text('Manuel taahhüt kaydedildi.'), findsOneWidget);
    });

    testWidgets('bütçe dışı taahhüt: maliyet kodu zorunlu, tutar > 0', (tester) async {
      final repo = await pump(tester, user: budgetOwnerUser, location: commitmentCreatePath(kProjectId));
      await tester.enterText(find.byKey(const ValueKey('commitment-description')), 'Alçı');
      await tester.enterText(find.byKey(const ValueKey('commitment-amount')), '0');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Maliyet kodu seç'), findsOneWidget);
      expect(find.text('Tutar sıfırdan büyük olmalıdır'), findsOneWidget);
      await selectDropdown(tester, 'commitment-cost-code', 'MLZ-004 — Alçı Sıva');
      await tester.enterText(find.byKey(const ValueKey('commitment-amount')), '85.000');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      final input = repo.commitmentInputs.single;
      expect(input.budgetLineId, isNull);
      expect(input.toJson()['budget_line_id'], '');
      expect(input.costCodeId, 'cc-mlz4');
      expect(input.amount, 85000);
    });

    testWidgets('yeniden deneme AYNI idempotency anahtarıyla gider', (tester) async {
      final repo = FakeBudgetRepository()
        ..errors['createCommitment'] = const ApiException(
          statusCode: null,
          message: 'Bağlantı kurulamadı.',
          kind: ApiErrorKind.network,
        );
      await pump(tester, user: budgetOwnerUser, location: commitmentCreatePath(kProjectId), repo: repo);
      await selectDropdown(tester, 'commitment-cost-code', 'MLZ-004 — Alçı Sıva');
      await tester.enterText(find.byKey(const ValueKey('commitment-description')), 'Alçı');
      await tester.enterText(find.byKey(const ValueKey('commitment-amount')), '100');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Bağlantı kurulamadı.'), findsOneWidget);
      repo.errors.remove('createCommitment');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(repo.commitmentInputs, hasLength(2));
      expect(repo.commitmentInputs[0].idempotencyKey, repo.commitmentInputs[1].idempotencyKey);
    });

    testWidgets('manuel taahhüt iptali: gerekçe zorunlu, void gövdesinde gider', (tester) async {
      final repo = await pump(tester, user: budgetOwnerUser, location: commitmentsPath(kProjectId));
      await tester.tap(find.text('Şantiye güvenlik hizmeti (Ekim)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('commitment-void')));
      await tester.pumpAndSettle();
      expect(find.textContaining('taahhüt toplamına dahil edilmeyecek'), findsOneWidget);
      final confirm = find.widgetWithText(TextButton, 'İptal Et');
      expect(tester.widget<TextButton>(confirm).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('budget-reason-field')), 'Hizmet alınmadı');
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(repo.voids.single, (id: 'c1', reason: 'Hizmet alınmadı'));
      expect(find.text('Taahhüt iptal edildi.'), findsOneWidget);
    });

    testWidgets('satın alma / taşeron taahhüdü buradan iptal edilemez', (tester) async {
      await pump(tester, user: budgetOwnerUser, location: commitmentsPath(kProjectId));
      await tester.tap(find.text('PO-2026-0014 · İnşaat demiri Ø12–Ø20'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('commitment-void')), findsNothing);
      expect(find.textContaining('satın alma siparişinin onayıyla oluştu'), findsOneWidget);
      await tester.tap(find.text('Kapat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('TSN-2026-0003 · Elektrik tesisatı'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('commitment-void')), findsNothing);
      expect(find.textContaining('taşeron sözleşmesinden oluştu'), findsOneWidget);
    });

    testWidgets('iptal 409 (zaten iptal): mesaj + liste tazelenir', (tester) async {
      final repo = FakeBudgetRepository()
        ..errors['voidCommitment'] = conflict('yalnızca aktif bir taahhüt iptal edilebilir');
      await pump(tester, user: budgetOwnerUser, location: commitmentsPath(kProjectId), repo: repo);
      final before = repo.count('commitments');
      await tester.tap(find.text('Şantiye güvenlik hizmeti (Ekim)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('commitment-void')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('budget-reason-field')), 'x');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'İptal Et'));
      await tester.pumpAndSettle();
      expect(find.text('yalnızca aktif bir taahhüt iptal edilebilir'), findsOneWidget);
      expect(repo.count('commitments'), greaterThan(before));
    });

    testWidgets('iptal edilenler süzmesi', (tester) async {
      await pump(tester, user: budgetOwnerUser, location: commitmentsPath(kProjectId));
      expect(find.text('Kalıp ekibi avans taahhüdü'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('commitments-show-voided')));
      await tester.pumpAndSettle();
      expect(find.text('Kalıp ekibi avans taahhüdü'), findsNothing);
    });
  });

  group('Tahmin ve Gerçekleşen', () {
    testWidgets('mevcut manuel ETC düzenlenir: alanlar dolu gelir', (tester) async {
      final repo = await pump(tester, user: budgetOwnerUser, location: forecastPath(kProjectId));
      await tester.tap(find.text('Düzenle').first); // l1 (manuel 40.000)
      await tester.pumpAndSettle();
      expect(find.text('ETC Tahminini Düzenle'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '40000'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('forecast-etc')), '55.000,5');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(repo.forecastInputs.single, (lineId: 'l1', etc: 55000.5, note: 'Kalan döküm 17 m³'));
    });

    testWidgets('ETC alanına eksi yazılamaz (negatif ETC yok)', (tester) async {
      final repo = await pump(tester, user: budgetOwnerUser, location: forecastPath(kProjectId));
      await tester.tap(find.text('Manuel ETC Gir').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('forecast-etc')), '-5');
      await tester.pump();
      expect(tester.widget<EditableText>(find.byType(EditableText).first).controller.text, '5');
      await tester.enterText(find.byKey(const ValueKey('forecast-etc')), '');
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('ETC (TRY) zorunludur'), findsOneWidget);
      expect(repo.count('upsertForecast'), 0);
    });

    testWidgets('gerçekleşen: maliyet koduna göre gruplar, iptal edilen masraf yok, eşlenmemiş notu', (tester) async {
      await pump(tester, user: budgetOwnerUser, location: actualCostPath(kProjectId));
      expect(find.text('MLZ-002 — İnşaat Demiri'), findsOneWidget);
      expect(find.text('İnşaat demiri Ø16 teslimatı'), findsOneWidget);
      expect(find.text('Hatalı giriş'), findsNothing);
      expect(find.textContaining('1 masraf kaydı henüz bir maliyet koduna eşlenmemiş'), findsOneWidget);
    });
  });
}
