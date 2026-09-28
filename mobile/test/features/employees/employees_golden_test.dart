@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/features/auth/domain/user.dart';

import '../access/access_test_support.dart';

/// Personel ekran görüntüleri (360x800): Sahip verisi (ücretler, hesap ve
/// yetkiler) ve salt-okunur "Personeli görüntüleme" kullanıcısı (ücret yok,
/// düzenleme yok). Üretmek:
///   flutter test --tags golden --update-goldens test/features/employees/employees_golden_test.dart
void main() {
  late ApiClient client;

  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    await loadAppFonts();
    client = await unscriptedClient();
  });

  Future<void> shoot(
    WidgetTester tester, {
    required String name,
    required User user,
    required String location,
    bool fullPage = false,
    Future<void> Function(WidgetTester tester)? before,
  }) async {
    // Gölgeler test motorunda varsayılan olarak siyah çizgiyle çizilir;
    // gerçek görünüm için açılır ve test bitmeden geri alınır.
    debugDisableShadows = false;
    try {
      tester.view.devicePixelRatio = 2.0;
      tester.view.physicalSize = const Size(360, 800) * 2.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(buildAccessApp(client: client, user: user, location: location));
      await tester.pumpAndSettle();
      if (before != null) await before(tester);
      if (fullPage) {
        final scrollable = tester.state<ScrollableState>(
          find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first,
        );
        final fullHeight = (800 + scrollable.position.maxScrollExtent).ceilToDouble();
        tester.view.physicalSize = Size(360, fullHeight) * 2.0;
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
    } finally {
      debugDisableShadows = true;
    }
  }

  testWidgets('personel listesi (sahip)', (tester) async {
    await shoot(tester, name: 'employees_list_owner_360x800', user: ownerUser, location: '/diger/personel');
  });

  testWidgets('personel listesi (salt-okunur)', (tester) async {
    await shoot(tester, name: 'employees_list_readonly_360x800', user: employeeViewerUser, location: '/diger/personel');
  });

  testWidgets('personel (yetkisiz)', (tester) async {
    await shoot(tester, name: 'employees_no_access_360x800', user: noAccessUser, location: '/diger/personel');
  });

  testWidgets('personel detayı (sahip, bağlı hesap)', (tester) async {
    await shoot(tester, name: 'employee_detail_owner_360x800', user: ownerUser, location: '/diger/personel/e1');
  });

  testWidgets('personel detayı tam sayfa (sahip, bağlı hesap)', (tester) async {
    await shoot(
      tester,
      name: 'employee_detail_owner_360_full',
      user: ownerUser,
      location: '/diger/personel/e1',
      fullPage: true,
    );
  });

  testWidgets('personel detayı (sahip, hesap yok)', (tester) async {
    await shoot(
      tester,
      name: 'employee_detail_no_login_owner_360x800',
      user: ownerUser,
      location: '/diger/personel/e2',
    );
  });

  testWidgets('personel detayı tam sayfa (salt-okunur)', (tester) async {
    await shoot(
      tester,
      name: 'employee_detail_readonly_360_full',
      user: employeeViewerUser,
      location: '/diger/personel/e1',
      fullPage: true,
    );
  });

  testWidgets('personel detayı (salt-okunur)', (tester) async {
    await shoot(
      tester,
      name: 'employee_detail_readonly_360x800',
      user: employeeViewerUser,
      location: '/diger/personel/e1',
    );
  });

  testWidgets('yeni personel formu (sahip)', (tester) async {
    await shoot(
      tester,
      name: 'employee_form_new_owner_360_full',
      user: ownerUser,
      location: '/diger/personel/yeni',
      fullPage: true,
      before: (tester) async {
        await tester.scrollUntilVisible(
          find.text('Yeni giriş hesabı aç'),
          200,
          scrollable: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Yeni giriş hesabı aç'));
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('personeli düzenle (sahip)', (tester) async {
    await shoot(
      tester,
      name: 'employee_form_edit_owner_360_full',
      user: ownerUser,
      location: '/diger/personel/e1/duzenle',
      fullPage: true,
    );
  });

  testWidgets('giriş hesabı aç (sahip)', (tester) async {
    await shoot(
      tester,
      name: 'employee_create_login_owner_360_full',
      user: ownerUser,
      location: '/diger/personel/e2/giris-hesabi',
      fullPage: true,
      before: (tester) async {
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Saha').last);
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('yeni personel formu 360x800 (sahip)', (tester) async {
    await shoot(tester, name: 'employee_form_new_owner_360x800', user: ownerUser, location: '/diger/personel/yeni');
  });

  testWidgets('personeli düzenle 360x800 (sahip)', (tester) async {
    await shoot(
      tester,
      name: 'employee_form_edit_owner_360x800',
      user: ownerUser,
      location: '/diger/personel/e1/duzenle',
    );
  });

  testWidgets('personel formu (salt-okunur -> kapalı)', (tester) async {
    await shoot(
      tester,
      name: 'employee_form_no_access_360x800',
      user: employeeViewerUser,
      location: '/diger/personel/e1/duzenle',
    );
  });

  testWidgets('giriş hesabı aç 360x800 (sahip)', (tester) async {
    await shoot(
      tester,
      name: 'employee_create_login_owner_360x800',
      user: ownerUser,
      location: '/diger/personel/e2/giris-hesabi',
    );
  });
}
