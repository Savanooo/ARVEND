import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/features/access/access_paths.dart';
import 'package:arvend/features/access/domain/access_models.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/employees/domain/employee_record.dart';

import 'access_test_support.dart';

/// "Kişi = tek kayıt" ekranları: Yeni Kullanıcı formunun "Personel Kaydı"
/// bölümü, kullanıcı detayındaki bağlı personel, personel listesindeki
/// hesap adı ve eşleşme önerileri. Sahada "batu" hesabı ile "Batuhan İnci"
/// personeli ayrı kalmış, görev bildirimi kimseye gitmemişti.
void main() {
  late ApiClient client;

  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    client = await unscriptedClient();
  });

  Finder field(String label) => find.widgetWithText(TextFormField, label);
  final dropdowns = find.byType(DropdownButtonFormField<String>);
  final submit = find.widgetWithText(ElevatedButton, 'Kullanıcı Oluştur');

  Future<void> fillAccount(WidgetTester tester, String fullName) async {
    await tester.enterText(field('Ad Soyad *'), fullName);
    await tester.enterText(field('Kullanıcı Adı *'), 'yeni.hesap');
    await tester.enterText(field('Şifre *'), 'guclu-sifre-1');
    await tester.tap(dropdowns.first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Saha').last);
    await tester.pumpAndSettle();
  }

  group('yeni kullanıcı: personel kaydı', () {
    testWidgets('aynı adlı bağlantısız personel önceden seçili; hesap ona bağlanır', (tester) async {
      final access = FakeAccessRepository()
        ..nextEmployeeLink = const EmployeeLink(
          status: EmployeeLink.linkedSameName,
          employeeId: 'e2',
          employeeFullName: 'Ahmet Yılmaz',
          message: 'Aynı adlı mevcut personel kaydına (Ahmet Yılmaz) bağlandı; ikinci bir kayıt açılmadı.',
        );
      final employees = FakeEmployeesRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: AccessPaths.newUser,
        access: access,
        employees: employees,
      );
      expect(find.text('Personel kaydı da oluştur'), findsOneWidget);

      // Telefon klavyesiyle büyük harf, Türkçe harfsiz yazılmış ad.
      await fillAccount(tester, 'AHMET YILMAZ');
      expect(find.text('"Ahmet Yılmaz" personel kaydı bu hesaba bağlanacak.'), findsOneWidget);

      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(access.lastPersonnel, (createEmployee: null, employeeId: 'e2', linkSameName: null));
      expect(find.textContaining('Aynı adlı mevcut personel kaydına (Ahmet Yılmaz) bağlandı'), findsOneWidget);
      expect(employees.employees.firstWhere((e) => e.id == 'e2').userId, isNotNull);
    });

    testWidgets('aynı ad varken "yeni kayıt" seçilirse sunucu aynı adlıya bağlamaz', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.newUser, access: access);
      await fillAccount(tester, 'Ahmet Yılmaz');

      await tester.ensureVisible(dropdowns.last);
      await tester.tap(dropdowns.last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yeni personel kaydı oluştur').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('yalnızca farklı bir kişiyse seç'), findsOneWidget);

      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(access.lastPersonnel, (createEmployee: true, employeeId: null, linkSameName: false));
    });

    testWidgets('anahtar kapatılırsa personel kaydı istenmez', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.newUser, access: access);
      await fillAccount(tester, 'Ofis Çalışanı');
      await tester.ensureVisible(find.text('Personel kaydı da oluştur'));
      await tester.tap(find.text('Personel kaydı da oluştur'));
      await tester.pumpAndSettle();
      expect(dropdowns, findsOneWidget); // yalnızca rol seçicisi kaldı

      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(access.lastPersonnel, (createEmployee: false, employeeId: null, linkSameName: null));
    });

    testWidgets('aynı adlı birden çok personel: yönetici seçmeden kaydedilmez', (tester) async {
      final access = FakeAccessRepository();
      final employees = FakeEmployeesRepository(
        employees: [
          ...sampleEmployees(),
          const EmployeeRecord(id: 'k1', fullName: 'Ali Kaya', position: 'Kalıpçı'),
          const EmployeeRecord(id: 'k2', fullName: 'ALİ KAYA', position: 'Demirci'),
        ],
      );
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: AccessPaths.newUser,
        access: access,
        employees: employees,
      );
      await fillAccount(tester, 'Ali Kaya');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.textContaining('Aynı adlı birden çok personel var'), findsOneWidget);
      expect(access.lastCreated, isNull);

      await tester.ensureVisible(dropdowns.last);
      await tester.tap(dropdowns.last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bağla: ALİ KAYA · Demirci').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(access.lastPersonnel?.employeeId, 'k2');
    });

    testWidgets('personel düzenleme izni olmayan yönetici: bölüm yok, alan gönderilmez', (tester) async {
      const admin = User(
        id: 'u-admin3',
        organizationId: 'org-1',
        username: 'deniz.er',
        fullName: 'Deniz Er',
        role: UserRole.admin,
        isActive: true,
        mustChangePassword: false,
        onboardingCompleted: true,
        onboardingStep: 'completed',
        organizationRoleCode: 'admin',
        organizationRoleName: 'Yönetici',
        permissions: {'organization.users.read', 'organization.users.manage', 'organization.roles.read'},
      );
      final access = FakeAccessRepository();
      final employees = FakeEmployeesRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: admin,
        location: AccessPaths.newUser,
        access: access,
        employees: employees,
      );
      expect(find.text('Personel Kaydı'), findsNothing);
      await fillAccount(tester, 'Ahmet Yılmaz');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(access.lastPersonnel, (createEmployee: null, employeeId: null, linkSameName: null));
      expect(employees.calls, isNot(contains('list aktif')));
    });
  });

  group('kullanıcı detayı: personel kaydı', () {
    testWidgets('bağlı personel görünür ve personel sayfasına götürür', (tester) async {
      await pumpAccessApp(tester, client: client, user: ownerUser, location: AccessPaths.user('u-pm'));
      expect(find.text('Personel kaydını aç'), findsOneWidget);
      await tester.tap(find.text('Personel kaydını aç'));
      await tester.pumpAndSettle();
      expect(find.text('Şantiye Şefi'), findsWidgets); // e1 detayı
    });

    testWidgets('kaydı olmayan hesaba personel kaydı açılır', (tester) async {
      final employees = FakeEmployeesRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: AccessPaths.user('u-legacy'),
        employees: employees,
      );
      expect(find.textContaining('Bu hesabın personel kaydı yok'), findsOneWidget);
      await scrollAndTap(tester, find.text('Personel Kaydı Oluştur'));
      final created = employees.created.single;
      expect(created.fullName, 'Hasan Aydın');
      expect(created.userId, 'u-legacy');
      expect(created.startDate, isNotNull);
      expect(find.text('Hasan Aydın personel kaydı oluşturuldu.'), findsOneWidget);
    });

    testWidgets('kaydı olmayan hesap mevcut personele bağlanır; ücretler korunur', (tester) async {
      final employees = FakeEmployeesRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: AccessPaths.user('u-legacy'),
        employees: employees,
      );
      await scrollAndTap(tester, find.text('Mevcut Personele Bağla'));
      // Yalnızca hesapsız aktif personel listelenir.
      expect(find.text('Mehmet Demir'), findsNothing);
      expect(find.text('İsmail Çelik'), findsNothing);
      await tester.tap(find.text('Fatma Şahin'));
      await tester.pumpAndSettle();

      final update = employees.updated.single;
      expect(update.id, 'e3');
      expect(update.input.userId, 'u-legacy');
      expect(update.input.salary, 62000);
      expect(update.input.position, 'Teknik Ofis');
    });

    testWidgets('personeli düzenleyemeyen: eksik bağ söylenir, düğme yok', (tester) async {
      await pumpAccessApp(tester, client: client, user: readOnlyAdminUser, location: AccessPaths.user('u-legacy'));
      expect(find.textContaining('Bu hesabın personel kaydı yok'), findsOneWidget);
      expect(find.text('Personel Kaydı Oluştur'), findsNothing);
    });
  });

  group('personel listesi: bağlı hesap ve öneriler', () {
    testWidgets('hesap adı satırda görünür; öneri onaylanınca bağlanır', (tester) async {
      final employees =
          FakeEmployeesRepository(
              employees: [
                const EmployeeRecord(
                  id: 'e1',
                  fullName: 'Mehmet Demir',
                  position: 'Şantiye Şefi',
                  userId: 'u-pm',
                  userUsername: 'mehmet.demir',
                  userIsActive: true,
                ),
                const EmployeeRecord(id: 'e3', fullName: 'Hasan Aydın', position: 'Teknik Ofis', salary: 62000),
              ],
            )
            ..suggestions = const [
              EmployeeLinkSuggestion(
                userId: 'u-legacy',
                username: 'hasan.aydin',
                userFullName: 'Hasan Aydın',
                employeeId: 'e3',
                employeeFullName: 'Hasan Aydın',
                employeePosition: 'Teknik Ofis',
              ),
            ];
      await pumpAccessApp(tester, client: client, user: ownerUser, location: '/diger/personel', employees: employees);

      expect(find.text('mehmet.demir'), findsOneWidget);
      expect(find.text('Bağlanmamış hesaplar (1)'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Bağla'));
      await tester.pumpAndSettle();
      final update = employees.updated.single;
      expect(update.id, 'e3');
      expect(update.input.userId, 'u-legacy');
      expect(update.input.salary, 62000);
    });

    testWidgets('kullanıcıları göremeyen: öneriler hiç istenmez', (tester) async {
      final employees = FakeEmployeesRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: employeeViewerUser,
        location: '/diger/personel',
        employees: employees,
      );
      expect(employees.calls, isNot(contains('linkSuggestions')));
      expect(find.textContaining('Bağlanmamış hesaplar'), findsNothing);
    });
  });
}
