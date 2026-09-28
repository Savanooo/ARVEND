import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/access/access_routes.dart';
import 'package:arvend/features/access/data/access_providers.dart';
import 'package:arvend/features/access/presentation/widgets/permission_checklist.dart';

import 'access_test_support.dart';

/// Düzenleyici ekranların emek koruması: kaydedilmemiş değişiklikte çıkış
/// onayı, yenilemenin seçimleri silmemesi, iki adımlı kaydın yarım kalması
/// ve salt-okunur matrisin yönlendirme metinleri.
void main() {
  late ApiClient client;

  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    client = await unscriptedClient();
  });

  final roleDropdown = find.byType(DropdownButtonFormField<String>);

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(Scaffold).last), listen: false);

  group('rol düzenleyici', () {
    testWidgets('kaydedilmemiş değişiklikle geri: onay sorulur; Vazgeç kalır, Çık listeye döner', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.role('r-pm'), access: access);
      await scrollAndTap(tester, find.textContaining('TEKLİFLER'));
      await scrollAndTap(tester, find.text('Teklif oluşturma'));
      expect(find.text('Kaydedilmedi'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Kaydedilmemiş değişiklikler var. Çıkmak istiyor musun?'), findsOneWidget);
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(find.text('Kaydedilmedi'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Çık'));
      await tester.pumpAndSettle();
      expect(find.text('Roller & Yetkiler'), findsOneWidget);
      expect(access.calls.where((c) => c.startsWith('setRolePermissions')), isEmpty);
    });

    testWidgets('değişiklik yokken geri onaysız', (tester) async {
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.role('r-pm'));
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Roller & Yetkiler'), findsOneWidget);
    });

    testWidgets('aşağı çekip yenileme (rol listesi tazelenir) kaydedilmemiş seçimi silmez', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.role('r-pm'), access: access);
      await scrollAndTap(tester, find.textContaining('TEKLİFLER'));
      await scrollAndTap(tester, find.text('Teklif oluşturma'));
      expect(find.text('Kaydedilmedi'), findsOneWidget);

      // RefreshIndicator'ın yaptığıyla aynı: rol listesi + katalog tazelenir.
      final container = containerOf(tester);
      container.invalidate(organizationRolesProvider);
      container.invalidate(permissionCatalogProvider);
      await tester.pumpAndSettle();
      expect(access.calls.where((c) => c == 'roles').length, greaterThanOrEqualTo(2));
      expect(find.text('Kaydedilmedi'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
      await tester.pumpAndSettle();
      expect(access.lastRolePermissions, contains('offers.create'));
      expect(find.text('Kaydedilmedi'), findsNothing);
    });

    testWidgets('izin listesinde sonuncu grubun altında ayırıcı yok (kart kenarlığıyla çift çizgi olmasın)', (
      tester,
    ) async {
      await pumpAccessApp(tester, client: client, user: readOnlyAdminUser, location: AccessPaths.role('r-pm'));
      final bordered = find.descendant(
        of: find.byType(PermissionChecklist),
        matching: find.byWidgetPredicate(
          (w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).border != null,
        ),
      );
      final categories = {for (final p in kCatalog) p.category}.length;
      expect(bordered, findsNWidgets(categories - 1));
    });
  });

  group('kişiye özel yetkiler', () {
    testWidgets('salt-okunur matris: "ekleyip çıkarabilirsin" yönlendirmeleri yok, tarafsız açıklama var', (
      tester,
    ) async {
      await pumpAccessApp(tester, client: client, user: readOnlyAdminUser, location: AccessPaths.user('u-pm'));
      await tester.scrollUntilVisible(find.text('Rol ve Yetkiler'), 200, scrollable: verticalScrollable);
      expect(find.textContaining('Yetkileri yalnızca görüntüleyebilirsin'), findsOneWidget);
      expect(
        find.text('Rol, yetkilerin başlangıç noktasıdır; kişiye özel farklar aşağıda işaretlidir.'),
        findsOneWidget,
      );
      expect(find.textContaining('Aşağıdan bu kişiye özel ekleme veya çıkarma yapabilirsin'), findsNothing);
      expect(find.textContaining('Bir yazma iznini açtığında'), findsNothing);
    });

    testWidgets('düzenleyebilen kişi yönlendirmeleri görür', (tester) async {
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-pm'));
      expect(find.textContaining('Aşağıdan bu kişiye özel ekleme veya çıkarma yapabilirsin'), findsOneWidget);
      expect(find.textContaining('Bir yazma iznini açtığında'), findsOneWidget);
    });

    testWidgets('rol yazıldı ama izinler yazılamadı: kart yeni rolü kayıtlı sayar, tekrar kayıt yalnız izinleri yazar', (
      tester,
    ) async {
      final access = FakeAccessRepository()..failNext['setUserPermissions'] = mapHttpError(500, 'izinler yazılamadı');
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-pm'), access: access);

      await tester.scrollUntilVisible(roleDropdown.last, 200, scrollable: verticalScrollable);
      await tester.tap(roleDropdown.last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Finans').last);
      await tester.pumpAndSettle();
      await scrollAndTap(tester, find.textContaining('PERSONEL'));
      await scrollAndTap(tester, find.text('Personeli düzenleme'));
      await scrollAndTap(tester, find.text('Rol ve Yetkileri Kaydet'));

      expect(access.calls.where((c) => c == 'setOrganizationRole u-pm finance').length, 1);
      expect(find.textContaining('Rol değiştirildi, ama kişiye özel yetkiler kaydedilemedi'), findsOneWidget);
      // Seçim korunur (kişiye özel fark hâlâ işaretli); "geri al" artık
      // eski role (Proje Yöneticisi) DEĞİL, sunucudaki yeni role döner.
      expect(find.textContaining('rolden 2 kişiye özel fark'), findsOneWidget);

      await scrollAndTap(tester, find.text('Rol ve Yetkileri Kaydet'));
      expect(access.calls.where((c) => c.startsWith('setOrganizationRole')).length, 1);
      expect(access.lastUserPermissions, containsAll(['employees.read', 'employees.manage']));
      expect(find.text('Rol ve yetkiler kaydedildi.'), findsOneWidget);
    });

    testWidgets('matriste kaydedilmemiş değişiklikle geri: onay sorulur', (tester) async {
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-pm'));
      await scrollAndTap(tester, find.textContaining('PERSONEL'));
      await scrollAndTap(tester, find.text('Personeli düzenleme'));
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Çık'));
      await tester.pumpAndSettle();
      expect(find.text('Kullanıcılar'), findsOneWidget);
    });

    testWidgets('yetki kaydı detayı tazeler ama yazılmakta olan ad silinmez', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-fin'), access: access);
      await tester.enterText(find.widgetWithText(TextField, 'Ad Soyad *'), 'Ayşe Kaya Demir');
      await tester.pump();

      await scrollAndTap(tester, find.textContaining('PERSONEL'));
      await scrollAndTap(tester, find.text('Personeli düzenleme'));
      await scrollAndTap(tester, find.text('Rol ve Yetkileri Kaydet'));
      expect(access.calls.where((c) => c == 'getUser u-fin').length, greaterThanOrEqualTo(2));

      await tester.scrollUntilVisible(find.text('Ayşe Kaya Demir'), -200, scrollable: verticalScrollable);
      expect(find.text('Ayşe Kaya Demir'), findsOneWidget);
    });
  });
}
