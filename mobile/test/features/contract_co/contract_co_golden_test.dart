@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/contract_co/contract_co_routes.dart';
import 'package:arvend/features/projects/contract_co/domain/project_contract.dart';

import 'contract_co_test_support.dart';

/// Sözleşme + Ek İşler ekran görüntüleri (360x800, PNG 720x1600, uygulama
/// fontlarıyla; uzun ekranlar için ayrıca tam boy "_360_full"):
/// sahip/yönetici, Proje Yöneticisi, salt-okunur ve yetkisiz. Üretmek:
///   flutter test --tags golden --update-goldens test/features/contract_co
/// Veri deterministik (sahte depo), ağ yok; saatler İstanbul saatiyle.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await loadAppFonts();
  });

  Future<void> pumpAt(
    WidgetTester tester, {
    required User user,
    required String location,
    FakeContractCoRepository? repo,
    String projectStatus = 'active',
  }) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(360, 800) * 2.0;
    addTearDown(tester.view.reset);
    // Gerçek gölge (flutter_test varsayılanı düz siyah blok); expectGolden
    // sonunda geri alınır.
    debugDisableShadows = false;
    await tester.pumpWidget(buildContractCoApp(
      user: user,
      repo: repo ?? FakeContractCoRepository(),
      initialLocation: location,
      project: sampleProject(status: projectStatus),
      theme: goldenTheme(),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> expectGolden(WidgetTester tester, String name) async {
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    debugDisableShadows = true;
  }

  /// Tüm içerik tek görüntüde: pencere, ilk kaydırılabilirin tam boyuna
  /// büyütülür. ListView çocukları tembel kurulduğu için kaydırma sınırı
  /// ilk ölçümde tahmindir -- sınır sıfıra inene kadar tekrarlanır.
  Future<void> growToFullHeight(WidgetTester tester) async {
    var height = 800.0;
    for (var i = 0; i < 6; i++) {
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
      final extra = scrollable.position.maxScrollExtent;
      if (extra <= 0) break;
      height = (height + extra).ceilToDouble();
      tester.view.physicalSize = Size(360, height) * 2.0;
      await tester.pumpAndSettle();
    }
  }

  group('Sözleşme', () {
    testWidgets('sahip, taslak', (tester) async {
      await pumpAt(tester, user: ownerUser, location: projectContractPath('p1'));
      await expectGolden(tester, 'contract_owner_draft_360x800');
    });

    testWidgets('sahip, taslak, tam boy', (tester) async {
      await pumpAt(tester, user: ownerUser, location: projectContractPath('p1'));
      await growToFullHeight(tester);
      await expectGolden(tester, 'contract_owner_draft_360_full');
    });

    testWidgets('Proje Yöneticisi (durum değiştiremez, tutar görmez), tam boy', (tester) async {
      await pumpAt(tester, user: pmUser, location: projectContractPath('p1'));
      await growToFullHeight(tester);
      await expectGolden(tester, 'contract_pm_draft_360_full');
    });

    testWidgets('finans, aktif', (tester) async {
      await pumpAt(
        tester,
        user: financeUser,
        location: projectContractPath('p1'),
        repo: FakeContractCoRepository(contract: sampleContract(status: ProjectContract.statusActive)),
      );
      await expectGolden(tester, 'contract_finance_active_360x800');
    });

    testWidgets('salt-okunur, aktif, tam boy', (tester) async {
      await pumpAt(
        tester,
        user: readOnlyUser,
        location: projectContractPath('p1'),
        repo: FakeContractCoRepository(contract: sampleContract(status: ProjectContract.statusActive)),
      );
      await growToFullHeight(tester);
      await expectGolden(tester, 'contract_readonly_active_360_full');
    });

    testWidgets('sözleşme yok (CTA)', (tester) async {
      await pumpAt(tester, user: ownerUser, location: projectContractPath('p1'), repo: FakeContractCoRepository(noContract: true));
      await expectGolden(tester, 'contract_empty_owner_360x800');
    });

    testWidgets('yetkisiz', (tester) async {
      await pumpAt(tester, user: fieldUser, location: projectContractPath('p1'));
      await expectGolden(tester, 'contract_no_access_360x800');
    });

    testWidgets('iptal gerekçesi penceresi', (tester) async {
      await pumpAt(tester, user: ownerUser, location: projectContractPath('p1'));
      await tester.tap(find.text('İptal Et'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Müşteri projeden vazgeçti');
      await tester.pumpAndSettle();
      await expectGolden(tester, 'contract_cancel_reason_360x800');
    });

    testWidgets('şartlar formu', (tester) async {
      await pumpAt(tester, user: ownerUser, location: projectContractEditPath('p1'));
      await expectGolden(tester, 'contract_form_360x800');
    });
  });

  group('Ek İşler', () {
    testWidgets('liste, sahip', (tester) async {
      await pumpAt(tester, user: ownerUser, location: projectChangeOrdersPath('p1'));
      await expectGolden(tester, 'change_orders_owner_360x800');
    });

    // Tam boy varyant yok: liste 360x800'e sığıyor, görüntü birebir aynıydı.

    testWidgets('liste, salt-okunur', (tester) async {
      await pumpAt(tester, user: readOnlyUser, location: projectChangeOrdersPath('p1'));
      await expectGolden(tester, 'change_orders_readonly_360x800');
    });

    testWidgets('liste, yetkisiz (Proje Yöneticisi)', (tester) async {
      await pumpAt(tester, user: pmUser, location: projectChangeOrdersPath('p1'));
      await expectGolden(tester, 'change_orders_no_access_360x800');
    });

    testWidgets('detay, taslak, sahip', (tester) async {
      await pumpAt(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co3'));
      await expectGolden(tester, 'change_order_draft_owner_360x800');
    });

    testWidgets('detay, taslak, sahip, tam boy', (tester) async {
      await pumpAt(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co3'));
      await growToFullHeight(tester);
      await expectGolden(tester, 'change_order_draft_owner_360_full');
    });

    testWidgets('detay, gönderildi, sahip', (tester) async {
      await pumpAt(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co4'));
      await expectGolden(tester, 'change_order_sent_owner_360x800');
    });

    testWidgets('detay, gönderildi, sahip, tam boy', (tester) async {
      await pumpAt(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co4'));
      await growToFullHeight(tester);
      await expectGolden(tester, 'change_order_sent_owner_360_full');
    });

    testWidgets('detay, gönderildi, salt-okunur', (tester) async {
      await pumpAt(tester, user: readOnlyUser, location: projectChangeOrderPath('p1', 'co4'));
      await expectGolden(tester, 'change_order_sent_readonly_360x800');
    });

    testWidgets('detay, reddedildi, sahip', (tester) async {
      await pumpAt(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co5'));
      await expectGolden(tester, 'change_order_rejected_owner_360x800');
    });

    testWidgets('detay, onaylandı, tam boy', (tester) async {
      await pumpAt(tester, user: financeUser, location: projectChangeOrderPath('p1', 'co1'));
      await growToFullHeight(tester);
      await expectGolden(tester, 'change_order_approved_finance_360_full');
    });

    testWidgets('mail gönder penceresi', (tester) async {
      await pumpAt(tester, user: ownerUser, location: projectChangeOrderPath('p1', 'co4'));
      await tester.tap(find.text('Mail Gönder'));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'change_order_email_sheet_360x800');
    });

    testWidgets('form, yeni', (tester) async {
      await pumpAt(tester, user: ownerUser, location: projectChangeOrderNewPath('p1'));
      await expectGolden(tester, 'change_order_form_create_360x800');
    });

    testWidgets('form, düzenle, tam boy', (tester) async {
      await pumpAt(tester, user: ownerUser, location: projectChangeOrderEditPath('p1', 'co3'));
      await growToFullHeight(tester);
      await expectGolden(tester, 'change_order_form_edit_360_full');
    });
  });
}
