import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/auth/permissions.dart';
import 'package:arvend/features/access/presentation/widgets/access_state_views.dart';
import 'package:arvend/features/employees/employees_routes.dart';
import 'package:arvend/features/employees/presentation/employee_form_screen.dart';
import 'package:arvend/features/employees/presentation/employees_screen.dart';

import '../access/access_test_support.dart';

/// Personel ekranları -- sahte repository'lerle (ağ yok): liste/filtre,
/// ücretlerin yalnızca employees.manage ile görünmesi, pasifleştirme,
/// yeni personel + giriş hesabı sırası, "Giriş hesabı aç" akışı, izin
/// kapıları ve 403'te çökmeme.
void main() {
  late ApiClient client;

  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    client = await unscriptedClient();
  });

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  group('liste', () {
    testWidgets('sahip: ücretler, yeni personel düğmesi ve aktif/pasif filtresi', (tester) async {
      final employees = FakeEmployeesRepository();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: EmployeesPaths.list, employees: employees);

      expect(find.text('Mehmet Demir'), findsOneWidget);
      expect(find.text('İsmail Çelik'), findsOneWidget);
      // Ücret kendi satırında, kısa biçimde (birim dar ekranda kesilmesin).
      expect(find.text('85.000\u00a0TL/ay'), findsOneWidget);
      expect(find.text('2.500\u00a0TL/gün'), findsOneWidget);
      expect(find.text('5 kişi'), findsOneWidget);
      expect(find.byTooltip('Yeni Personel'), findsOneWidget);
      expect(find.text(kEmployeesReadOnlyText), findsNothing);

      await tester.tap(find.text('Pasif').first);
      await tester.pumpAndSettle();
      expect(find.text('İsmail Çelik'), findsOneWidget);
      expect(find.text('Mehmet Demir'), findsNothing);
      expect(employees.calls, ['list', 'list pasif']);

      await tester.tap(find.text('Aktif').first);
      await tester.pumpAndSettle();
      expect(find.text('4 kişi'), findsOneWidget);
      expect(find.text('İsmail Çelik'), findsNothing);
    });

    testWidgets('yalnızca görüntüleme: ücret yok, ekleme yok, açıklama var', (tester) async {
      await pumpAccessApp(tester, client: client, user: employeeViewerUser, location: EmployeesPaths.list);

      expect(find.text('Mehmet Demir'), findsOneWidget);
      expect(find.textContaining('TL'), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text(kEmployeesReadOnlyText), findsOneWidget);

      await tester.tap(find.text('Ahmet Yılmaz'));
      await tester.pumpAndSettle();
      expect(find.text('Personel Bilgileri'), findsOneWidget);
    });

    for (final (name, user) in [('izin yok', noAccessUser), ('izin kümesi boş', emptyPermissionsUser)]) {
      testWidgets('$name: kilit mesajı, API hiç çağrılmaz', (tester) async {
        final employees = FakeEmployeesRepository();
        await pumpAccessApp(tester, client: client, user: user, location: EmployeesPaths.list, employees: employees);
        expect(find.text(kEmployeesNoAccessText), findsOneWidget);
        expect(employees.calls, isEmpty);
      });
    }

    testWidgets('sunucu 403 dönerse çökmeden açık mesaj', (tester) async {
      final employees = FakeEmployeesRepository()..failAlways['list'] = forbidden();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: EmployeesPaths.list, employees: employees);
      expect(find.text(kForbiddenMessage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('boş liste', (tester) async {
      final employees = FakeEmployeesRepository(employees: []);
      await pumpAccessApp(tester, client: client, user: ownerUser, location: EmployeesPaths.list, employees: employees);
      expect(find.text('Personel bulunamadı.'), findsOneWidget);
    });
  });

  group('detay', () {
    testWidgets('sahip: ücretler, bağlı hesap ve kişiye özel yetkiler', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: EmployeesPaths.detail('e1'),
        access: access,
      );

      expect(find.text('Aylık Maaş'), findsOneWidget);
      expect(find.text('85.000,00 TL'), findsOneWidget);
      expect(find.byTooltip('Düzenle'), findsOneWidget);
      // Yıkıcı işlem etiketli kırmızı düğme olarak sayfanın sonunda.
      expect(find.widgetWithText(OutlinedButton, 'Pasifleştir'), findsOneWidget);
      // Bağlı hesap satırı + rol/yetki kartı.
      expect(find.text('mehmet.demir · Proje Yöneticisi'), findsOneWidget);
      expect(find.textContaining('rolden 2 kişiye özel fark'), findsOneWidget);
      expect(access.calls, containsAll(['getUser u-pm', 'getUserPermissions u-pm', 'roles', 'permissionCatalog']));
    });

    testWidgets('pasifleştirme onay ister; vazgeçince istek atılmaz', (tester) async {
      final employees = FakeEmployeesRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: EmployeesPaths.detail('e2'),
        employees: employees,
      );

      final archiveButton = find.widgetWithText(OutlinedButton, 'Pasifleştir');
      await tester.ensureVisible(archiveButton);
      await tester.tap(archiveButton);
      await tester.pumpAndSettle();
      expect(find.text('Personeli Pasifleştir'), findsOneWidget);
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(employees.calls.where((c) => c.startsWith('archive')), isEmpty);

      await tester.ensureVisible(archiveButton);
      await tester.tap(archiveButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Pasifleştir'));
      await tester.pumpAndSettle();
      expect(employees.calls, contains('archive e2'));
      expect(find.text('Pasif'), findsOneWidget);
      // Pasif kayıtta pasifleştirme düğmesi kalkar; üst çubukta simgeli
      // bir pasifleştirme de yok.
      expect(archiveButton, findsNothing);
      expect(find.byTooltip('Pasifleştir'), findsNothing);
    });

    testWidgets('yalnızca görüntüleme: ücret satırı yok, düzenleme yok, yetkiler gizli', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: employeeViewerUser,
        location: EmployeesPaths.detail('e1'),
        access: access,
      );

      expect(find.text('Günlük Yevmiye'), findsNothing);
      expect(find.text('Aylık Maaş'), findsNothing);
      expect(find.textContaining('TL'), findsNothing);
      expect(find.byTooltip('Düzenle'), findsNothing);
      expect(find.byTooltip('Pasifleştir'), findsNothing);
      expect(find.text('Bu personelin sisteme giriş hesabı var.'), findsOneWidget);
      expect(access.calls, isEmpty);
    });

    testWidgets('kaba rolü admin olmayan yönetici: kullanıcı/rol uçları hiç çağrılmaz', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: nonAdminManagerUser,
        location: EmployeesPaths.detail('e2'),
        access: access,
      );
      // employees.manage var: ücret görünür, ama hesap açma dört izin ister.
      expect(find.text('Günlük Yevmiye'), findsOneWidget);
      expect(find.text('Bu personelin sisteme giriş hesabı yok.'), findsOneWidget);
      expect(find.text('Giriş Hesabı Aç'), findsNothing);
      expect(access.calls, isEmpty);
    });

    testWidgets('personel 403 dönerse açık mesaj', (tester) async {
      final employees = FakeEmployeesRepository()..failAlways['get'] = forbidden();
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: EmployeesPaths.detail('e1'),
        employees: employees,
      );
      expect(find.text(kForbiddenMessage), findsOneWidget);
    });
  });

  group('giriş hesabı aç', () {
    Future<void> fillAndSubmit(WidgetTester tester) async {
      await tester.enterText(field('Kullanıcı Adı *'), 'ahmet.yilmaz');
      await tester.enterText(field('Şifre *'), 'guclu-sifre-1');
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saha').last);
      await tester.pumpAndSettle();
      // Kişiye özel: rolde olmayan "Teklif oluşturma" (+ görüntüleme de açılır).
      await scrollAndTap(tester, find.textContaining('TEKLİFLER'));
      await scrollAndTap(tester, find.text('Teklif oluşturma'));
      await scrollAndTap(tester, find.text('Giriş Hesabı Oluştur'));
    }

    testWidgets('hesap açılır, personele bağlanır (ücretler korunur), yetkiler yazılır', (tester) async {
      final access = FakeAccessRepository();
      final employees = FakeEmployeesRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: EmployeesPaths.detail('e2'),
        access: access,
        employees: employees,
      );

      await scrollAndTap(tester, find.text('Giriş Hesabı Aç'));
      expect(find.text('Giriş Bilgileri'), findsOneWidget);
      await fillAndSubmit(tester);

      expect(access.lastCreated?.username, 'ahmet.yilmaz');
      expect(access.lastCreated?.fullName, 'Ahmet Yılmaz');
      expect(access.lastCreated?.roleCode, 'field');
      final createdId = access.users.last.id;

      final update = employees.updated.single;
      expect(update.id, 'e2');
      expect(update.input.userId, createdId);
      expect(update.input.dailyWage, 2500);
      expect(update.input.startDate, '2025-05-12');
      expect(update.input.position, 'Kalıpçı Ustası');

      // Rol hesap açılırken verildi -> yalnızca kişiye özel izinler yazılır.
      expect(access.calls.where((c) => c.startsWith('setOrganizationRole')), isEmpty);
      final createIdx = access.calls.indexWhere((c) => c.startsWith('createUser'));
      expect(access.calls.indexOf('setUserPermissions $createdId'), greaterThan(createIdx));
      expect(access.lastUserPermissions, containsAll(['offers.read', 'offers.create', 'projects.read']));

      // Detaya dönüldü; artık bağlı hesap görünür.
      expect(find.textContaining('giriş hesabı açıldı'), findsOneWidget);
      expect(find.text('Giriş Hesabı Aç'), findsNothing);
    });

    testWidgets('bağlama başarısız olursa tekrar denemek hesabı yeniden açmaz', (tester) async {
      final access = FakeAccessRepository();
      final employees = FakeEmployeesRepository()..failNext['update'] = badRequest('personel güncellenemedi');
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: EmployeesPaths.createLogin('e2'),
        access: access,
        employees: employees,
      );

      await fillAndSubmit(tester);
      expect(find.textContaining('giriş hesabı oluşturuldu ama bu personele bağlanamadı'), findsOneWidget);
      expect(find.text('Tekrar Dene'), findsOneWidget);

      await scrollAndTap(tester, find.text('Tekrar Dene'));
      expect(access.calls.where((c) => c.startsWith('createUser')).length, 1);
      expect(employees.updated.length, 2);
      expect(employees.employees.firstWhere((e) => e.id == 'e2').userId, isNotNull);
    });

    testWidgets('yetkiler yazılamazsa detay uyarı gösterir', (tester) async {
      final access = FakeAccessRepository()..failNext['setUserPermissions'] = forbidden();
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: EmployeesPaths.detail('e2'),
        access: access,
      );
      await scrollAndTap(tester, find.text('Giriş Hesabı Aç'));
      await fillAndSubmit(tester);
      expect(find.textContaining('kişiye özel yetkiler kaydedilemedi'), findsOneWidget);
    });

    testWidgets('dört izin yoksa ekran kapalı', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: usersOnlyAdminUser,
        location: EmployeesPaths.createLogin('e2'),
        access: access,
      );
      expect(find.byType(NoAccessView), findsOneWidget);
      expect(access.calls, isEmpty);
    });
  });

  group('form', () {
    testWidgets('zorunlu alan ve tutar doğrulaması', (tester) async {
      final employees = FakeEmployeesRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: EmployeesPaths.create,
        employees: employees,
      );

      await tester.enterText(field('Aylık Maaş'), '1,2,3');
      await scrollAndTap(tester, find.text('Personel Ekle'));
      expect(find.text('Ad soyad zorunludur'), findsOneWidget);
      expect(find.text('Geçerli bir tutar gir'), findsOneWidget);
      expect(employees.created, isEmpty);
    });

    testWidgets('yeni personel + yeni giriş hesabı: hesap -> personel -> yetkiler', (tester) async {
      final access = FakeAccessRepository();
      final employees = FakeEmployeesRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: EmployeesPaths.create,
        access: access,
        employees: employees,
      );

      await tester.enterText(field('Ad Soyad *'), 'Selin Ak');
      await tester.enterText(field('Görev'), 'Mimar');
      await tester.enterText(field('Günlük Yevmiye'), '2.750');
      await scrollAndTap(tester, find.text('Yeni giriş hesabı aç'));
      await tester.enterText(field('Kullanıcı Adı *'), 'selin.ak');
      await tester.enterText(field('Şifre *'), 'guclu-sifre-1');
      await scrollAndTap(tester, find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.text('Finans').last);
      await tester.pumpAndSettle();
      await scrollAndTap(tester, find.text('Personel Ekle'));

      expect(access.lastCreated?.username, 'selin.ak');
      expect(access.lastCreated?.fullName, 'Selin Ak');
      expect(access.lastCreated?.roleCode, 'finance');
      final createdId = access.users.last.id;
      final created = employees.created.single;
      expect(created.userId, createdId);
      expect(created.dailyWage, 2750);
      expect(created.position, 'Mimar');
      final createIdx = access.calls.indexWhere((c) => c.startsWith('createUser'));
      expect(access.calls.indexOf('setUserPermissions $createdId'), greaterThan(createIdx));

      // Listeye dönüldü.
      expect(find.text('Selin Ak eklendi.'), findsOneWidget);
      expect(find.text('Selin Ak'), findsOneWidget);
    });

    testWidgets('hesap açılıp personel kaydı başarısız olursa tekrar denemek ikinci hesap açmaz', (tester) async {
      final access = FakeAccessRepository();
      final employees = FakeEmployeesRepository()..failNext['create'] = badRequest('geçersiz işe başlama tarihi');
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: EmployeesPaths.create,
        access: access,
        employees: employees,
      );

      await tester.enterText(field('Ad Soyad *'), 'Selin Ak');
      await scrollAndTap(tester, find.text('Yeni giriş hesabı aç'));
      await tester.enterText(field('Kullanıcı Adı *'), 'selin.ak');
      await tester.enterText(field('Şifre *'), 'guclu-sifre-1');
      await scrollAndTap(tester, find.byType(DropdownButtonFormField<String>));
      await tester.tap(find.text('Saha').last);
      await tester.pumpAndSettle();
      await scrollAndTap(tester, find.text('Personel Ekle'));

      expect(find.textContaining('Giriş hesabı oluşturuldu ama personel kaydedilemedi'), findsOneWidget);
      await scrollAndTap(tester, find.text('Personel Ekle'));

      expect(access.calls.where((c) => c.startsWith('createUser')).length, 1);
      expect(employees.created.length, 2);
      expect(employees.created.last.userId, access.users.last.id);
    });

    testWidgets('düzenle: bağlantı ve ücretler korunarak tam gövde yazılır', (tester) async {
      final employees = FakeEmployeesRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: EmployeesPaths.edit('e1'),
        employees: employees,
      );

      expect(find.text('85000'), findsOneWidget);
      await tester.enterText(field('Görev'), 'Proje Müdürü');
      await scrollAndTap(tester, find.text('Kaydet'));

      final update = employees.updated.single;
      expect(update.id, 'e1');
      expect(update.input.position, 'Proje Müdürü');
      expect(update.input.salary, 85000);
      expect(update.input.userId, 'u-pm');
      expect(update.input.startDate, '2024-03-01');
      expect(update.input.isActive, isTrue);
      // Detaya dönüldü.
      expect(find.text('Personel Bilgileri'), findsOneWidget);
    });

    testWidgets('kullanıcıları göremeyen yönetici bağlantıyı değiştiremez, mevcut bağlantı korunur', (tester) async {
      final employees = FakeEmployeesRepository();
      final access = FakeAccessRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: nonAdminManagerUser,
        location: EmployeesPaths.edit('e1'),
        employees: employees,
        access: access,
      );

      expect(find.textContaining('Bağlı kullanıcı hesabı: var'), findsOneWidget);
      await scrollAndTap(tester, find.text('Kaydet'));
      expect(employees.updated.single.input.userId, 'u-pm');
      expect(access.calls, isEmpty);
    });

    testWidgets('yeni personel: giriş seçenekleri izinlere göre', (tester) async {
      await pumpAccessApp(tester, client: client, user: nonAdminManagerUser, location: EmployeesPaths.create);
      expect(find.text('Giriş hesabı yok'), findsOneWidget);
      expect(find.text('Mevcut hesaba bağla'), findsNothing);
      expect(find.text('Yeni giriş hesabı aç'), findsNothing);
    });

    testWidgets('yalnızca görüntüleme izniyle form kapalı', (tester) async {
      final employees = FakeEmployeesRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: employeeViewerUser,
        location: EmployeesPaths.edit('e1'),
        employees: employees,
      );
      expect(find.text(kEmployeeManageNoAccessMessage), findsOneWidget);
      // Alttaki liste/detay sayfaları okur; form hiçbir yazma isteği atmaz.
      expect(employees.updated, isEmpty);
      expect(find.text('Kaydet'), findsNothing);
    });
  });

  test('menü öğesi KATI izinle süzülür', () {
    expect(employeesMenuEntries.single.route, '/diger/personel');
    expect(ownerUser.canAccess(employeesMenuEntries.single.permission), isTrue);
    expect(employeeViewerUser.canAccess(employeesMenuEntries.single.permission), isTrue);
    expect(noAccessUser.canAccess(employeesMenuEntries.single.permission), isFalse);
    expect(emptyPermissionsUser.canAccess(employeesMenuEntries.single.permission), isFalse);
  });
}
