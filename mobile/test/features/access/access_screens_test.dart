import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/auth/permissions.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/access/access_routes.dart';
import 'package:arvend/features/access/presentation/users_screen.dart';
import 'package:arvend/features/access/presentation/widgets/access_state_views.dart';

import 'access_test_support.dart';

/// Kullanıcılar + kişiye özel yetki matrisi + Roller & Yetkiler -- sahte
/// repository'lerle (ağ yok). Web `PermissionMatrix`/`UserAccessCard`/
/// `RolesManager` davranışı ve KATI izin kapıları.
void main() {
  late ApiClient client;

  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    client = await unscriptedClient();
  });

  Finder field(String label) => find.widgetWithText(TextFormField, label);
  Finder textField(String label) => find.widgetWithText(TextField, label);
  // Yeni kullanıcı formunda rolün altında "Personel kaydı" seçicisi de var.
  final roleDropdown = find.byType(DropdownButtonFormField<String>).first;

  group('kullanıcı listesi', () {
    testWidgets('sahip: liste, arama, aktif/pasif filtresi ve yeni kullanıcı', (tester) async {
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.users);

      expect(find.text('6 kullanıcı · 5 aktif'), findsOneWidget);
      expect(find.text('Kemal Arslan'), findsOneWidget);
      expect(find.text('hasan.aydin · Kullanıcı (Eski Sistem)'), findsOneWidget);
      expect(find.byTooltip('Yeni Kullanıcı'), findsOneWidget);
      expect(find.text(kUsersReadOnlyText), findsNothing);

      await tester.enterText(find.byType(TextField), 'KAYA');
      await tester.pumpAndSettle();
      expect(find.text('Ayşe Kaya'), findsOneWidget);
      expect(find.text('Kemal Arslan'), findsNothing);

      // Kullanıcı adıyla da aranır.
      await tester.enterText(find.byType(TextField), 'ali.ozturk');
      await tester.pumpAndSettle();
      expect(find.text('Ali Öztürk'), findsOneWidget);
      expect(find.text('Ayşe Kaya'), findsNothing);

      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pasif').first);
      await tester.pumpAndSettle();
      expect(find.text('Ali Öztürk'), findsOneWidget);
      expect(find.text('Kemal Arslan'), findsNothing);

      await tester.enterText(find.byType(TextField), 'yok-boyle-biri');
      await tester.pumpAndSettle();
      expect(find.text('Aramana uyan kullanıcı yok.'), findsOneWidget);
    });

    testWidgets('yalnızca görüntüleme: ekleme yok, açıklama var, satır detaya gider', (tester) async {
      await pumpAccessApp(tester, client: client, user: readOnlyAdminUser, location: AccessPaths.users);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text(kUsersReadOnlyText), findsOneWidget);
      await tester.tap(find.text('Mehmet Demir'));
      await tester.pumpAndSettle();
      expect(find.text('Kullanıcı Bilgileri'), findsOneWidget);
    });

    testWidgets('kullanıcıları düzenleyebilen ama rolleri göremeyen yönetici yeni kullanıcı açamaz', (tester) async {
      await pumpAccessApp(tester, client: client, user: usersOnlyAdminUser, location: AccessPaths.users);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text(kUsersReadOnlyText), findsNothing);
    });

    for (final (name, user) in [
      ('kaba rolü admin olmayan (izni olsa bile)', nonAdminManagerUser),
      ('izin kümesi boş', emptyPermissionsUser),
    ]) {
      testWidgets('$name: kilit mesajı, API çağrılmaz', (tester) async {
        final access = FakeAccessRepository();
        await pumpAccessApp(tester, client: client, user: user, location: AccessPaths.users, access: access);
        expect(find.text(kUsersNoAccessText), findsOneWidget);
        expect(access.calls, isEmpty);
      });
    }

    testWidgets('sunucu 403 -> açık mesaj, çökme yok', (tester) async {
      final access = FakeAccessRepository()..failAlways['listUsers'] = forbidden();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.users, access: access);
      expect(find.text(kForbiddenMessage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('diğer hatalarda tekrar dene', (tester) async {
      final access = FakeAccessRepository()..failNext['listUsers'] = mapHttpError(500, null);
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.users, access: access);
      expect(find.text('Tekrar Dene'), findsOneWidget);
      await tester.tap(find.text('Tekrar Dene'));
      await tester.pumpAndSettle();
      expect(find.text('Kemal Arslan'), findsOneWidget);
    });
  });

  group('kullanıcı detayı', () {
    testWidgets('bilgiler kaydedilir; pasifleştirme onay ister', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-pm'), access: access);

      await tester.enterText(textField('Ad Soyad *'), 'Mehmet Demirci');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
      await tester.pumpAndSettle();
      expect(access.calls, contains('updateUser u-pm Mehmet Demirci true'));

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Kullanıcıyı Pasifleştir'), findsOneWidget);
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(access.calls.where((c) => c.endsWith('false')), isEmpty);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Pasifleştir'));
      await tester.pumpAndSettle();
      expect(access.calls, contains('updateUser u-pm Mehmet Demirci false'));
      expect(find.text('Pasif'), findsWidgets);
    });

    testWidgets('atandığı projeler listelenir ve projeye gider', (tester) async {
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-pm'));
      expect(find.text('Kadıköy Konut Projesi'), findsOneWidget);
      expect(find.text('Üye'), findsOneWidget);
      await tester.tap(find.text('Kadıköy Konut Projesi'));
      await tester.pumpAndSettle();
      expect(find.text('PROJE p1'), findsOneWidget);
    });

    testWidgets('projesi olmayan kullanıcı için açıklama', (tester) async {
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-fin'));
      expect(find.textContaining('açıkça hiçbir projeye atanmamış'), findsOneWidget);
    });

    testWidgets('şifre sıfırlama: 8 karakter kuralı, sonra istek', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-pm'), access: access);

      await tester.enterText(textField('Yeni Şifre'), 'kisa');
      await tester.pumpAndSettle();
      await scrollAndTap(tester, find.text('Şifreyi Sıfırla'));
      expect(find.text('Şifre en az 8 karakter olmalı.'), findsOneWidget);
      expect(access.calls.where((c) => c.startsWith('resetPassword')), isEmpty);

      await tester.enterText(textField('Yeni Şifre'), 'yeterince-uzun');
      await tester.pumpAndSettle();
      await scrollAndTap(tester, find.text('Şifreyi Sıfırla'));
      expect(access.calls, contains('resetPassword u-pm'));
      expect(access.lastPassword, 'yeterince-uzun');
      expect(find.textContaining('Şifre sıfırlandı.'), findsOneWidget);
    });

    testWidgets('yalnızca görüntüleme: form, şifre ve kaydet düğmeleri yok', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: readOnlyAdminUser,
        location: AccessPaths.user('u-pm'),
        access: access,
      );
      expect(find.textContaining('Bu kullanıcıyı yalnızca görüntüleyebilirsin'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Şifre Sıfırla'), findsNothing);
      expect(find.textContaining('Yetkileri yalnızca görüntüleyebilirsin'), findsOneWidget);
      expect(find.text('Rol ve Yetkileri Kaydet'), findsNothing);
      expect(allCheckboxesDisabled(tester), isTrue);
    });

    testWidgets('rolleri göremeyen yönetici: yetki bölümü yok, izin uçları çağrılmaz', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: usersOnlyAdminUser,
        location: AccessPaths.user('u-pm'),
        access: access,
      );
      expect(find.text('Rol ve Yetkiler'), findsNothing);
      expect(find.text('Şifre Sıfırla'), findsOneWidget);
      expect(access.calls.where((c) => c.startsWith('getUserPermissions') || c == 'roles'), isEmpty);
    });

    testWidgets('kaba rolü admin olmayan: detay kapalı', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: nonAdminManagerUser,
        location: AccessPaths.user('u-pm'),
        access: access,
      );
      expect(find.text(kUsersNoAccessText), findsWidgets);
      expect(access.calls, isEmpty);
    });
  });

  group('kişiye özel yetki matrisi', () {
    testWidgets('işaretler, fark sayısı ve rolün varsayılanına dönüş', (tester) async {
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-pm'));

      expect(find.textContaining('rolden 2 kişiye özel fark'), findsOneWidget);
      // Farkı olan kategoriler açık başlar.
      expect(find.textContaining('+ kişiye özel'), findsOneWidget);
      expect(find.textContaining('− kişiye özel'), findsOneWidget);

      await scrollAndTap(tester, find.textContaining('MÜŞTERİLER'));
      await scrollAndTap(tester, find.text('Müşterileri düzenleme'));
      expect(find.textContaining('rolden 3 kişiye özel fark'), findsOneWidget);

      await scrollAndTap(tester, find.text('Rolün varsayılanına dön'));
      expect(find.textContaining('rolün varsayılanı'), findsOneWidget);
      expect(find.text('Rolün varsayılanına dön'), findsNothing);
      expect(find.textContaining('kişiye özel'), findsNothing);
    });

    testWidgets('yazma izni görüntülemeyi açar; kayıt yalnızca izinleri yazar', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-fin'), access: access);

      await scrollAndTap(tester, find.textContaining('PERSONEL'));
      await scrollAndTap(tester, find.text('Personeli düzenleme'));
      expect(find.textContaining('rolden 2 kişiye özel fark'), findsOneWidget);

      await scrollAndTap(tester, find.text('Rol ve Yetkileri Kaydet'));
      expect(access.calls.where((c) => c.startsWith('setOrganizationRole')), isEmpty);
      expect(access.calls, contains('setUserPermissions u-fin'));
      expect(access.lastUserPermissions, containsAll(['employees.read', 'employees.manage', 'offers.read']));
      expect(find.text('Rol ve yetkiler kaydedildi.'), findsOneWidget);
    });

    testWidgets('görüntüleme kapanınca bağlı yazma izinleri de kapanır', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-pm'), access: access);

      // Teklifler açık başlar (kişiye özel "Teklif oluşturma" var).
      await scrollAndTap(tester, find.text('Teklifleri görüntüleme'));
      await scrollAndTap(tester, find.text('Rol ve Yetkileri Kaydet'));
      expect(access.lastUserPermissions, isNot(contains('offers.read')));
      expect(access.lastUserPermissions, isNot(contains('offers.create')));
    });

    testWidgets('rol değişince önce rol, sonra izinler yazılır; kutucuklar rolün varsayılanına döner', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-pm'), access: access);

      await tester.scrollUntilVisible(roleDropdown, 200, scrollable: verticalScrollable);
      await tester.tap(roleDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Finans').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('rolün varsayılanı'), findsOneWidget);

      await scrollAndTap(tester, find.text('Rol ve Yetkileri Kaydet'));
      final roleIdx = access.calls.indexOf('setOrganizationRole u-pm finance');
      expect(roleIdx, greaterThanOrEqualTo(0));
      expect(access.calls.indexOf('setUserPermissions u-pm'), greaterThan(roleIdx));
      expect(access.lastUserPermissions, sampleRoles().firstWhere((r) => r.code == 'finance').permissions.toSet());
    });

    testWidgets('Sahip/Yönetici dışındaki rolde yönetici izinleri kilitli, "Tümünü Seç" yok', (tester) async {
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-pm'));

      await scrollAndTap(tester, find.textContaining('FİRMA YÖNETİMİ'));
      expect(find.textContaining('(yalnızca Sahip/Yönetici)'), findsNWidgets(4));
      expect(categoryAction(tester, 'FİRMA YÖNETİMİ'), findsNothing);
      await tester.tap(find.textContaining('Kullanıcıları görüntüleme'));
      await tester.pumpAndSettle();
      expect(find.textContaining('rolden 2 kişiye özel fark'), findsOneWidget);
    });

    testWidgets('kategori "Tümünü Seç" yazma+görüntüleme kuralıyla açar', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-fin'), access: access);

      final action = categoryAction(tester, 'TEKLİFLER');
      expect(tester.widget<Text>(find.descendant(of: action, matching: find.byType(Text))).data, 'Tümünü Seç');
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.textContaining('TEKLİFLER  (5/5)'), findsOneWidget);
      expect(
        tester.widget<Text>(find.descendant(of: categoryAction(tester, 'TEKLİFLER'), matching: find.byType(Text))).data,
        'Tümünü Kaldır',
      );
    });

    testWidgets('Sahip kilitli: kutucuklar kapalı, açıklama görünür', (tester) async {
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-owner'));
      expect(find.textContaining('Sahip her zaman tüm yetkilere sahiptir'), findsOneWidget);
      await scrollAndTap(tester, find.textContaining('PROJELER'));
      expect(allCheckboxesDisabled(tester), isTrue);
    });

    testWidgets('listede olmayan eski rol "(mevcut rol)" olarak korunur', (tester) async {
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-legacy'));
      expect(find.text('Kullanıcı (Eski Sistem) (mevcut rol)'), findsOneWidget);
      expect(find.textContaining('rolün varsayılanı'), findsOneWidget);
    });

    testWidgets('kaydetme hatası mesajla gösterilir', (tester) async {
      final access = FakeAccessRepository()
        ..failNext['setUserPermissions'] = badRequest('bu izin yalnızca yöneticilere');
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-fin'), access: access);
      await scrollAndTap(tester, find.textContaining('PERSONEL'));
      await scrollAndTap(tester, find.text('Personeli görüntüleme'));
      await scrollAndTap(tester, find.text('Rol ve Yetkileri Kaydet'));
      expect(find.text('bu izin yalnızca yöneticilere'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('kişi kendi yetkilerini değiştirince oturum tazelenir', (tester) async {
      final auth = FakeAuth(fullAdminUser);
      await pumpAccessApp(
        tester,
        client: client,
        user: fullAdminUser,
        location: AccessPaths.user('u-admin'),
        auth: auth,
      );
      await scrollAndTap(tester, find.textContaining('TEKLİFLER'));
      await scrollAndTap(tester, find.text('Teklif silme'));
      await scrollAndTap(tester, find.text('Rol ve Yetkileri Kaydet'));
      expect(auth.refreshCount, 1);
    });
  });

  group('yeni kullanıcı', () {
    testWidgets('rol seçilmeden kaydedilemez; doğrulama; başarılı kayıt listeye döner', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.newUser, access: access);

      // Düğme hep etkin: boş formda basınca TÜM eksikler (rol dahil)
      // alanların altında söylenir, istek atılmaz.
      final submit = find.widgetWithText(ElevatedButton, 'Kullanıcı Oluştur');
      expect(tester.widget<ElevatedButton>(submit).onPressed, isNotNull);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.text('Ad soyad zorunludur'), findsOneWidget);
      expect(find.text('Kullanıcı adı zorunludur'), findsOneWidget);
      expect(find.text('Şifre en az 8 karakter olmalı'), findsOneWidget);
      expect(find.text('Rol seçmelisin'), findsOneWidget);
      expect(access.lastCreated, isNull);

      await tester.enterText(field('Ad Soyad *'), 'Selin Ak');
      await tester.enterText(field('Kullanıcı Adı *'), 'selin.ak');
      await tester.enterText(field('Şifre *'), 'kisa');
      await tester.tap(roleDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saha').last);
      await tester.pumpAndSettle();
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.text('Şifre en az 8 karakter olmalı'), findsOneWidget);
      expect(access.lastCreated, isNull);

      await tester.enterText(field('Şifre *'), 'guclu-sifre-1');
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(access.lastCreated, (
        username: 'selin.ak',
        password: 'guclu-sifre-1',
        fullName: 'Selin Ak',
        roleCode: 'field',
      ));
      expect(find.text('Kullanıcı oluşturuldu.'), findsOneWidget);
      expect(find.text('7 kullanıcı · 6 aktif'), findsOneWidget);
    });

    testWidgets('sunucu hatası formda gösterilir', (tester) async {
      final access = FakeAccessRepository()
        ..failNext['createUser'] = mapHttpError(409, 'bu kullanıcı adı zaten kullanılıyor');
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.newUser, access: access);
      await tester.enterText(field('Ad Soyad *'), 'Selin Ak');
      await tester.enterText(field('Kullanıcı Adı *'), 'kemal.arslan');
      await tester.enterText(field('Şifre *'), 'guclu-sifre-1');
      await tester.tap(roleDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saha').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Kullanıcı Oluştur'));
      await tester.pumpAndSettle();
      expect(find.text('bu kullanıcı adı zaten kullanılıyor'), findsOneWidget);
    });

    testWidgets('rolleri göremeyen yönetici için form kapalı', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: usersOnlyAdminUser,
        location: AccessPaths.newUser,
        access: access,
      );
      expect(find.byType(NoAccessView), findsOneWidget);
      expect(access.calls.where((c) => c == 'roles'), isEmpty);
    });
  });

  group('roller', () {
    testWidgets('liste: roller ve izin sayıları', (tester) async {
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.roles);
      expect(find.text('Proje Yöneticisi'), findsOneWidget);
      expect(find.text('12 izin'), findsOneWidget);
      expect(find.text('25 izin'), findsNWidgets(2));
      await tester.tap(find.text('Saha'));
      await tester.pumpAndSettle();
      expect(find.text('Sistem rolü'), findsOneWidget);
    });

    testWidgets('rol izinleri düzenlenir ve kaydedilir; geri al', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.role('r-pm'), access: access);

      final save = find.widgetWithText(ElevatedButton, 'Kaydet');
      expect(tester.widget<ElevatedButton>(save).onPressed, isNull);

      await scrollAndTap(tester, find.textContaining('TEKLİFLER'));
      await scrollAndTap(tester, find.text('Teklif oluşturma'));
      expect(find.text('Kaydedilmedi'), findsOneWidget);
      await tester.tap(find.text('Geri Al'));
      await tester.pumpAndSettle();
      expect(find.text('Kaydedilmedi'), findsNothing);

      await scrollAndTap(tester, find.text('Teklif oluşturma'));
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(access.calls, contains('setRolePermissions r-pm'));
      expect(access.lastRolePermissions, contains('offers.create'));
      expect(access.lastRolePermissions!.length, 13);
      expect(find.text('Kaydedildi.'), findsOneWidget);
    });

    testWidgets('kendi rolünü düzenleyen kişinin oturumu tazelenir', (tester) async {
      final auth = FakeAuth(fullAdminUser);
      await pumpAccessApp(
        tester,
        client: client,
        user: fullAdminUser,
        location: AccessPaths.role('r-admin'),
        auth: auth,
      );
      await scrollAndTap(tester, find.textContaining('TEKLİFLER'));
      await scrollAndTap(tester, find.text('Teklif silme'));
      await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
      await tester.pumpAndSettle();
      expect(auth.refreshCount, 1);
    });

    testWidgets('Sahip rolü kilitli', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: AccessPaths.role('r-owner'),
        access: access,
      );
      expect(find.textContaining('Sahip rolü kilitlidir'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Kaydet'), findsNothing);
      await scrollAndTap(tester, find.textContaining('PROJELER'));
      expect(allCheckboxesDisabled(tester), isTrue);
      expect(categoryActionButtons, findsNothing);
    });

    testWidgets('yalnızca görüntüleme', (tester) async {
      await pumpAccessApp(tester, client: client, user: readOnlyAdminUser, location: AccessPaths.role('r-pm'));
      expect(find.textContaining('Rolün yetkilerini yalnızca görüntüleyebilirsin'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Kaydet'), findsNothing);
      expect(categoryActionButtons, findsNothing);
    });

    testWidgets('kaydetme hatası mesajla gösterilir', (tester) async {
      final access = FakeAccessRepository()..failNext['setRolePermissions'] = forbidden();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.role('r-pm'), access: access);
      await scrollAndTap(tester, find.textContaining('TEKLİFLER'));
      await scrollAndTap(tester, find.text('Teklif oluşturma'));
      await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('bu işlem için yetkiniz yok'), findsOneWidget);
      expect(find.text('Kaydedilmedi'), findsOneWidget);
    });

    testWidgets('bilinmeyen rol', (tester) async {
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.role('r-yok'));
      expect(find.text('Rol bulunamadı.'), findsOneWidget);
    });

    for (final (name, user) in [('kaba rolü admin olmayan', nonAdminManagerUser), ('izin yok', noAccessUser)]) {
      testWidgets('$name: kilit, API çağrılmaz', (tester) async {
        final access = FakeAccessRepository();
        await pumpAccessApp(tester, client: client, user: user, location: AccessPaths.roles, access: access);
        expect(find.byType(NoAccessView), findsOneWidget);
        expect(access.calls, isEmpty);
      });
    }
  });

  test('menü öğeleri KATI izinle süzülür (Yönetici\'ye kilitli)', () {
    expect(accessMenuEntries.map((e) => e.route), ['/diger/kullanicilar', '/diger/roller']);
    expect(
      [
        for (final e in accessMenuEntries)
          if (ownerUser.canAccess(e.permission)) e.label,
      ],
      ['Kullanıcılar', 'Roller & Yetkiler'],
    );
    expect(
      [
        for (final e in accessMenuEntries)
          if (usersOnlyAdminUser.canAccess(e.permission)) e.label,
      ],
      ['Kullanıcılar'],
    );
    expect([
      for (final e in accessMenuEntries)
        if (nonAdminManagerUser.canAccess(e.permission)) e.label,
    ], isEmpty);
    expect([
      for (final e in accessMenuEntries)
        if (emptyPermissionsUser.canAccess(e.permission)) e.label,
    ], isEmpty);
  });
}
