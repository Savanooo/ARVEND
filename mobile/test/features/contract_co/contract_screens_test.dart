import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/widgets/access_notices.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/contract_co/contract_co_routes.dart';
import 'package:arvend/features/projects/contract_co/domain/project_contract.dart';
import 'package:arvend/features/projects/contract_co/presentation/widgets/contract_co_ui.dart';

import 'contract_co_test_support.dart';

/// Sözleşme ekranı: üç katmanlı izin (read/manage/lifecycle), 404 -> CTA,
/// 403 -> çökmeden "yetkin yok", durum geçişleri (onay + zorunlu gerekçe),
/// 409 tazeleme, proje kapalıyken aksiyon yok, tutar yalnızca finans izniyle.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  Future<FakeContractCoRepository> pump(
    WidgetTester tester, {
    required User user,
    FakeContractCoRepository? repo,
    String location = '/projeler/p1/sozlesme',
    String projectStatus = 'active',
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 1600);
    addTearDown(tester.view.reset);
    final r = repo ?? FakeContractCoRepository();
    await tester.pumpWidget(buildContractCoApp(
      user: user,
      repo: r,
      initialLocation: location,
      project: sampleProject(status: projectStatus),
    ));
    await tester.pumpAndSettle();
    return r;
  }

  group('izinler', () {
    testWidgets('sahip + taslak: yaşam döngüsü, düzenleme, ek işler ve tutarlar görünür', (tester) async {
      await pump(tester, user: ownerUser);
      expect(find.text('Taslak — şartlar serbestçe düzenlenebilir.'), findsOneWidget);
      expect(find.text('Aktifleştir'), findsOneWidget);
      expect(find.text('İptal Et'), findsOneWidget);
      expect(find.text('Tamamla'), findsNothing);
      expect(find.text('Feshet'), findsNothing);
      expect(find.byTooltip('Şartları Düzenle'), findsOneWidget);
      expect(find.byTooltip('Notu Düzenle'), findsOneWidget);
      expect(find.byType(ReadOnlyNotice), findsNothing);
      await tester.scrollUntilVisible(find.text('Bu Sözleşmeyi Değiştiren Ek İşler'), 300);
      expect(find.text('Güncel Proje Bedeli'), findsOneWidget);
      expect(find.textContaining('EK-004 · Eksiltme'), findsOneWidget);
    });

    testWidgets('Proje Yöneticisi: taslağı düzenler ama durumu değiştiremez, tutar görmez', (tester) async {
      final repo = await pump(tester, user: pmUser);
      expect(find.text('Aktifleştir'), findsNothing);
      expect(find.text('İptal Et'), findsNothing);
      expect(find.byTooltip('Şartları Düzenle'), findsOneWidget);
      expect(find.byTooltip('Notu Düzenle'), findsOneWidget);
      expect(find.text(kContractNoLifecycleText), findsOneWidget);
      // Finans izni yok: ek iş listesi/özeti hiç istenmez, ekranda para yok.
      expect(find.text('Bu Sözleşmeyi Değiştiren Ek İşler'), findsNothing);
      expect(find.textContaining('TL'), findsNothing);
      expect(repo.calls, isNot(contains('changeOrders')));
      expect(repo.calls, isNot(contains('summary')));
    });

    testWidgets('salt-okunur: hiçbir yazma aksiyonu yok, bilgilendirme kutusu var', (tester) async {
      await pump(tester, user: readOnlyUser, repo: FakeContractCoRepository(contract: sampleContract(status: 'active')));
      expect(find.text('Tamamla'), findsNothing);
      expect(find.text('Feshet'), findsNothing);
      expect(find.byTooltip('Şartları Düzenle'), findsNothing);
      expect(find.byTooltip('Notu Düzenle'), findsNothing);
      expect(find.text(kContractReadOnlyText), findsOneWidget);
      expect(
        find.text('Aktivasyon sonrası ticari şartlar kilitlidir — değişiklik için resmi bir Ek İş gereklidir.'),
        findsOneWidget,
      );
    });

    testWidgets('izin yok: API çağrılmadan "yetkin yok"', (tester) async {
      final repo = await pump(tester, user: fieldUser);
      expect(find.byType(NoAccessView), findsOneWidget);
      expect(find.text(kContractNoAccessText), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('sunucu 403: çökmez, "yetkin yok"', (tester) async {
      final repo = FakeContractCoRepository()..contractError = forbidden;
      await pump(tester, user: ownerUser, repo: repo);
      expect(tester.takeException(), isNull);
      expect(find.text(kContractNoAccessText), findsOneWidget);
    });

    testWidgets('proje tamamlandı, taslak sözleşme: şart/not/aktivasyon yok; kapanış (İptal Et) var', (tester) async {
      // Backend yaşam döngüsünü proje kilidine BİLİNÇLİ bağlamıyor: kapalı
      // projede sözleşmeyi kapatmak anlamlı bir kapanış eylemidir.
      final repo = await pump(tester, user: ownerUser, projectStatus: 'completed');
      expect(find.text('Aktifleştir'), findsNothing);
      expect(find.byTooltip('Şartları Düzenle'), findsNothing);
      expect(find.byTooltip('Notu Düzenle'), findsNothing);
      expect(find.text('İptal Et'), findsOneWidget);
      expect(find.text(kContractLockedClosingText), findsOneWidget);
      await tester.tap(find.text('İptal Et'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Proje kapandı');
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'İptal Et'));
      await tester.pumpAndSettle();
      expect(repo.reasons, ['Proje kapandı']);
    });

    testWidgets('proje tamamlandı, aktif sözleşme: Tamamla ve Feshet görünür', (tester) async {
      await pump(
        tester,
        user: ownerUser,
        projectStatus: 'completed',
        repo: FakeContractCoRepository(contract: sampleContract(status: ProjectContract.statusActive)),
      );
      expect(find.text('Tamamla'), findsOneWidget);
      expect(find.text('Feshet'), findsOneWidget);
      expect(find.text(kContractLockedClosingText), findsOneWidget);
    });

    testWidgets('proje tamamlandı, yaşam döngüsü izni yok: hiç aksiyon yok, kilit notu', (tester) async {
      await pump(tester, user: pmUser, projectStatus: 'completed');
      expect(find.text('İptal Et'), findsNothing);
      expect(find.text('Aktifleştir'), findsNothing);
      expect(find.text(kProjectLockedText), findsOneWidget);
    });
  });

  group('sözleşmesiz proje (404)', () {
    testWidgets('yönetici "Sözleşme Oluştur" ile taslak açar', (tester) async {
      final repo = await pump(tester, user: pmUser, repo: FakeContractCoRepository(noContract: true));
      expect(find.text('Bu proje için henüz bir sözleşme yok'), findsOneWidget);
      await tester.tap(find.text('Sözleşme Oluştur'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('createContract'));
      expect(find.text('Taslak'), findsOneWidget);
      expect(find.text('Sözleşme taslağı oluşturuldu.'), findsOneWidget);
    });

    testWidgets('salt-okunur kullanıcıya CTA yok; yapamayacağı adımı anlatan cümle yerine izin notu', (tester) async {
      await pump(tester, user: readOnlyUser, repo: FakeContractCoRepository(noContract: true));
      expect(find.text('Bu proje için henüz bir sözleşme yok'), findsOneWidget);
      expect(find.text('Sözleşme Oluştur'), findsNothing);
      expect(find.textContaining('doldurabilirsin'), findsNothing);
      expect(find.text('Bu proje için henüz sözleşme oluşturulmadı.'), findsOneWidget);
      expect(find.text(kContractCreateReadOnlyText), findsOneWidget);
    });

    testWidgets('409 (başkası oluşturdu): mesaj + mevcut sözleşme yüklenir', (tester) async {
      final repo = FakeContractCoRepository(noContract: true)..writeError = conflict('bu projenin zaten bir sözleşmesi var');
      await pump(tester, user: ownerUser, repo: repo);
      repo.currentContract = sampleContract();
      await tester.tap(find.text('Sözleşme Oluştur'));
      await tester.pumpAndSettle();
      expect(find.text('bu projenin zaten bir sözleşmesi var'), findsOneWidget);
      expect(find.text('Aktifleştir'), findsOneWidget);
    });
  });

  group('durum geçişleri', () {
    testWidgets('Aktifleştir: onay penceresi -> aktif', (tester) async {
      final repo = await pump(tester, user: ownerUser);
      await tester.tap(find.text('Aktifleştir'));
      await tester.pumpAndSettle();
      expect(find.text('Sözleşmeyi Aktifleştir'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Aktifleştir'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('activateContract'));
      expect(find.text('Aktif'), findsOneWidget);
      expect(find.text('Tamamla'), findsOneWidget);
      expect(find.text('Feshet'), findsOneWidget);
      expect(find.byTooltip('Şartları Düzenle'), findsNothing);
      expect(find.byTooltip('Notu Düzenle'), findsOneWidget);
    });

    testWidgets('Vazgeç: hiçbir istek atılmaz', (tester) async {
      final repo = await pump(tester, user: ownerUser);
      await tester.tap(find.text('Aktifleştir'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(repo.calls, isNot(contains('activateContract')));
    });

    testWidgets('İptal Et gerekçe olmadan onaylanamaz; gerekçe gönderilir', (tester) async {
      final repo = await pump(tester, user: ownerUser);
      await tester.tap(find.text('İptal Et'));
      await tester.pumpAndSettle();
      expect(find.text('Sözleşmeyi İptal Et'), findsOneWidget);
      final confirm = find.widgetWithText(TextButton, 'İptal Et');
      expect(tester.widget<TextButton>(confirm).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'Müşteri projeden vazgeçti');
      await tester.pump();
      expect(tester.widget<TextButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(repo.reasons, ['Müşteri projeden vazgeçti']);
      expect(find.text('İptal Edildi'), findsWidgets);
      expect(find.text('Aktifleştir'), findsNothing);
    });

    testWidgets('Feshet gerekçeyle', (tester) async {
      final repo = await pump(
        tester,
        user: financeUser,
        repo: FakeContractCoRepository(contract: sampleContract(status: 'active')),
      );
      await tester.tap(find.text('Feshet'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Ödeme yapılmadı');
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Feshet'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('terminateContract'));
      expect(repo.reasons, ['Ödeme yapılmadı']);
      expect(find.text('Feshedildi — Ödeme yapılmadı.'), findsOneWidget);
    });

    testWidgets('409: sunucu mesajı gösterilir ve sözleşme yeniden okunur', (tester) async {
      final repo = FakeContractCoRepository()
        ..writeError = conflict('yalnızca taslak durumundaki bir sözleşme aktive edilebilir');
      await pump(tester, user: ownerUser, repo: repo);
      final before = repo.calls.where((c) => c == 'contract').length;
      repo.currentContract = sampleContract(status: ProjectContract.statusActive);
      await tester.tap(find.text('Aktifleştir'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Aktifleştir'));
      await tester.pumpAndSettle();
      expect(find.text('yalnızca taslak durumundaki bir sözleşme aktive edilebilir'), findsOneWidget);
      expect(repo.calls.where((c) => c == 'contract').length, greaterThan(before));
      expect(find.text('Tamamla'), findsOneWidget);
    });

    testWidgets('403 yazma hatası sabit metinle gösterilir', (tester) async {
      final repo = FakeContractCoRepository()..writeError = forbidden;
      await pump(tester, user: ownerUser, repo: repo);
      await tester.tap(find.text('Aktifleştir'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Aktifleştir'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Bu işlem için yetkin yok.'), findsOneWidget);
    });
  });

  group('düzenleme', () {
    testWidgets('şartlar formu: değişiklikler PUT edilir, ekrana döner', (tester) async {
      final repo = await pump(tester, user: pmUser);
      await tester.tap(find.byTooltip('Şartları Düzenle'));
      await tester.pumpAndSettle();
      expect(find.text('Sözleşme Şartları'), findsWidgets);
      await tester.enterText(find.widgetWithText(TextField, 'Ödeme Koşulları'), 'Peşin ödeme');
      await tester.tap(find.byTooltip('Temizle').first);
      await tester.pump();
      await tester.tap(find.text('Kaydet'));
      await tester.pumpAndSettle();
      expect(repo.draftUpdates, hasLength(1));
      final input = repo.draftUpdates.single;
      expect(input.paymentTerms, 'Peşin ödeme');
      expect(input.effectiveDate, isNull);
      expect(input.toJson()['effective_date'], isNull);
      expect(input.plannedCompletionDate, '2026-12-15');
      // Sözleşme ekranına dönüldü, yeni değer görünüyor.
      expect(find.text('Peşin ödeme'), findsOneWidget);
    });

    testWidgets('aktif sözleşmede şart formu kilitli', (tester) async {
      await pump(
        tester,
        user: ownerUser,
        repo: FakeContractCoRepository(contract: sampleContract(status: 'active')),
        location: projectContractEditPath('p1'),
      );
      expect(find.textContaining('yalnızca taslak durumdayken düzenlenebilir'), findsOneWidget);
      expect(find.text('Kaydet'), findsNothing);
    });

    testWidgets('şart formu izin olmadan açılmaz', (tester) async {
      final repo = await pump(tester, user: readOnlyUser, location: projectContractEditPath('p1'));
      expect(find.byType(NoAccessView), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('dahili not: sayfada düzenlenip kaydedilir', (tester) async {
      final repo = await pump(tester, user: ownerUser);
      await tester.tap(find.byTooltip('Notu Düzenle'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Avans %15 olarak kesinleşti.');
      await tester.tap(find.text('Notu Kaydet'));
      await tester.pumpAndSettle();
      expect(repo.notesUpdates, ['Avans %15 olarak kesinleşti.']);
      expect(find.text('Avans %15 olarak kesinleşti.'), findsOneWidget);
      expect(find.text('Not kaydedildi.'), findsOneWidget);
    });
  });
}
