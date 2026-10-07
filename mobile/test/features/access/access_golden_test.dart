@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/features/auth/domain/user.dart';

import 'access_test_support.dart';

/// Kullanıcılar + Roller & Yetkiler ekran görüntüleri (360x800, Sahip
/// verisi ve salt-okunur Yönetici). Üretmek:
///   flutter test --tags golden --update-goldens test/features/access/access_golden_test.dart
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

  testWidgets('kullanıcılar listesi (sahip)', (tester) async {
    await shoot(tester, name: 'users_list_owner_360x800', user: ownerUser, location: '/diger/kullanicilar');
  });

  testWidgets('kullanıcılar listesi (salt-okunur yönetici)', (tester) async {
    await shoot(tester, name: 'users_list_readonly_360x800', user: readOnlyAdminUser, location: '/diger/kullanicilar');
  });

  testWidgets('kullanıcılar (yetkisiz)', (tester) async {
    await shoot(tester, name: 'users_no_access_360x800', user: noAccessUser, location: '/diger/kullanicilar');
  });

  testWidgets('kullanıcı detayı (sahip)', (tester) async {
    await shoot(tester, name: 'user_detail_owner_360x800', user: ownerUser, location: '/diger/kullanicilar/u-pm');
  });

  testWidgets('kullanıcı detayı tam sayfa (sahip)', (tester) async {
    await shoot(
      tester,
      name: 'user_detail_owner_360_full',
      user: ownerUser,
      location: '/diger/kullanicilar/u-pm',
      fullPage: true,
    );
  });

  testWidgets('kullanıcı detayı (salt-okunur yönetici)', (tester) async {
    await shoot(
      tester,
      name: 'user_detail_readonly_360x800',
      user: readOnlyAdminUser,
      location: '/diger/kullanicilar/u-pm',
    );
  });

  testWidgets('kullanıcı detayı tam sayfa (salt-okunur yönetici)', (tester) async {
    await shoot(
      tester,
      name: 'user_detail_readonly_360_full',
      user: readOnlyAdminUser,
      location: '/diger/kullanicilar/u-pm',
      fullPage: true,
    );
  });

  testWidgets('yeni kullanıcı formu (sahip)', (tester) async {
    await shoot(tester, name: 'user_form_owner_360x800', user: ownerUser, location: '/diger/kullanicilar/yeni');
  });

  testWidgets('roller listesi (sahip)', (tester) async {
    await shoot(tester, name: 'roles_list_owner_360x800', user: ownerUser, location: '/diger/roller');
  });

  testWidgets('rol detayı (sahip)', (tester) async {
    await shoot(
      tester,
      name: 'role_detail_owner_360x800',
      user: ownerUser,
      location: '/diger/roller/r-pm',
      before: (tester) async {
        // İki kategoriyi aç, birinde değişiklik yap -> "Kaydedilmedi" + kaydet çubuğu.
        await tester.tap(find.textContaining('TEKLİFLER'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Teklif oluşturma'));
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('rol detayı (salt-okunur yönetici)', (tester) async {
    await shoot(tester, name: 'role_detail_readonly_360x800', user: readOnlyAdminUser, location: '/diger/roller/r-pm');
  });

  testWidgets('sahip rolü kilitli', (tester) async {
    await shoot(tester, name: 'role_detail_owner_locked_360x800', user: ownerUser, location: '/diger/roller/r-owner');
  });

  testWidgets('yeni kullanıcı formu (yetkisiz)', (tester) async {
    await shoot(
      tester,
      name: 'user_form_no_access_360x800',
      user: readOnlyAdminUser,
      location: '/diger/kullanicilar/yeni',
    );
  });

  testWidgets('yeni kullanıcı formu doldurulmuş (sahip)', (tester) async {
    await shoot(
      tester,
      name: 'user_form_filled_owner_360x800',
      user: ownerUser,
      location: '/diger/kullanicilar/yeni',
      before: (tester) async {
        await tester.enterText(find.widgetWithText(TextFormField, 'Ad Soyad *'), 'Selin Ak');
        await tester.enterText(find.widgetWithText(TextFormField, 'Kullanıcı Adı *'), 'selin.ak');
        // İlk seçici rol; altındaki "Personel kaydı" seçicisi.
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Finans').last);
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('roller listesi (salt-okunur yönetici)', (tester) async {
    await shoot(tester, name: 'roles_list_readonly_360x800', user: readOnlyAdminUser, location: '/diger/roller');
  });

  testWidgets('eski sistem rolündeki kullanıcı (sahip)', (tester) async {
    await shoot(
      tester,
      name: 'user_detail_legacy_owner_360_full',
      user: ownerUser,
      location: '/diger/kullanicilar/u-legacy',
      fullPage: true,
    );
  });
}
