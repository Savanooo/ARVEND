import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/employees/domain/employee_record.dart';
import 'package:arvend/features/employees/employees_routes.dart';

import '../access/access_test_support.dart';

/// Çok adımlı personel kayıtlarının dayanıklılığı: ağ yavaşken sıranın
/// sonucu kaybetmemesi, kayıt sürerken sayfadan çıkılamaması, okunamayan
/// hesap yetkilerinin sessizce ezilmemesi ve kısa ücret gösterimi.
void main() {
  late ApiClient client;

  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    client = await unscriptedClient();
  });

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  Future<void> fillCreateLogin(WidgetTester tester) async {
    await tester.enterText(field('Kullanıcı Adı *'), 'ahmet.yilmaz');
    await tester.enterText(field('Şifre *'), 'guclu-sifre-1');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Saha').last);
    await tester.pumpAndSettle();
    await scrollAndTap(tester, find.textContaining('TEKLİFLER'));
    await scrollAndTap(tester, find.text('Teklif oluşturma'));
  }

  group('giriş hesabı aç', () {
    testWidgets('yetki kaydı personel tazelemesinden SONRA biterse form sökülmez; uyarı detaya ulaşır', (
      tester,
    ) async {
      final gate = Completer<void>();
      final access = FakeAccessRepository()
        ..hold['setUserPermissions'] = gate
        ..failNext['setUserPermissions'] = badRequest('bu izin yalnızca yönetici rolünde verilebilir');
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
      await fillCreateLogin(tester);
      await tester.ensureVisible(find.text('Giriş Hesabı Oluştur'));
      await tester.tap(find.text('Giriş Hesabı Oluştur'));
      // Hesap açıldı, personele bağlandı; yetki isteği ağda sürüyor. Bu
      // sırada birkaç kare geçer (eski sırada personel kaydı burada
      // tazelenip formu "zaten hesabı var" notuyla değiştiriyordu).
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(employees.updated.single.input.userId, isNotNull);
      expect(find.text('Bu personelin zaten bir giriş hesabı var.'), findsNothing);
      expect(find.text('Giriş Bilgileri'), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      // Detaya dönüldü ve yetki uyarısı kaybolmadı.
      expect(find.text('Giriş Bilgileri'), findsNothing);
      expect(find.textContaining('kişiye özel yetkiler kaydedilemedi'), findsOneWidget);
      expect(find.text('Giriş Hesabı Aç'), findsNothing);
    });

    testWidgets('kayıt sürerken geri engellenir; bitince detaya dönülür', (tester) async {
      final gate = Completer<void>();
      final access = FakeAccessRepository()..hold['createUser'] = gate;
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: EmployeesPaths.detail('e2'),
        access: access,
      );
      await scrollAndTap(tester, find.text('Giriş Hesabı Aç'));
      await fillCreateLogin(tester);
      await tester.ensureVisible(find.text('Giriş Hesabı Oluştur'));
      await tester.tap(find.text('Giriş Hesabı Oluştur'));
      await tester.pump();

      await tester.tap(find.byType(BackButton));
      await tester.pump();
      expect(find.text('Kaydediliyor, lütfen bitmesini bekle.'), findsOneWidget);
      expect(find.text('Giriş Bilgileri'), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();
      // "Kaydediliyor" notu kısa sürer; ardından başarı mesajı görünür.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.textContaining('giriş hesabı açıldı'), findsOneWidget);
      expect(find.text('Giriş Hesabı Aç'), findsNothing);
    });

    testWidgets('yarım bırakılan form (yazılmış bilgi) çıkarken onay ister', (tester) async {
      await pumpAccessApp(tester, client: client, user: ownerUser, location: EmployeesPaths.detail('e2'));
      await scrollAndTap(tester, find.text('Giriş Hesabı Aç'));
      await tester.enterText(field('Kullanıcı Adı *'), 'ahmet');
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Çık'));
      await tester.pumpAndSettle();
      expect(find.text('Giriş Hesabı Aç'), findsOneWidget);
    });

    testWidgets('düğme hep etkin: rol seçilmeden basınca eksikler söylenir, istek atılmaz', (tester) async {
      final access = FakeAccessRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: EmployeesPaths.createLogin('e2'),
        access: access,
      );
      final button = find.widgetWithText(ElevatedButton, 'Giriş Hesabı Oluştur');
      expect(tester.widget<ElevatedButton>(button).onPressed, isNotNull);
      await scrollAndTap(tester, button);
      expect(find.text('Rol seçmelisin.'), findsOneWidget);
      expect(find.text('Kullanıcı adı zorunludur'), findsOneWidget);
      expect(access.calls.where((c) => c.startsWith('createUser')), isEmpty);
    });
  });

  group('yeni personel formu', () {
    testWidgets('mevcut hesabın yetkileri okunamazsa matris gizli, tekrar dene var, kayıt yetkilere dokunmaz', (
      tester,
    ) async {
      final access = FakeAccessRepository()..failNext['getUserPermissions'] = mapHttpError(null, null);
      final employees = FakeEmployeesRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: EmployeesPaths.create,
        access: access,
        employees: employees,
      );
      await tester.enterText(field('Ad Soyad *'), 'Hasan Aydın');
      await scrollAndTap(tester, find.text('Mevcut hesaba bağla'));
      await scrollAndTap(tester, find.widgetWithText(DropdownButtonFormField<String>, 'Giriş Hesabı *'));
      await tester.tap(find.textContaining('hasan.aydin').last);
      await tester.pumpAndSettle();

      expect(find.textContaining('Hesabın rol ve yetkileri alınamadı'), findsOneWidget);
      expect(find.text('Tekrar Dene'), findsOneWidget);
      expect(find.textContaining('rolün varsayılanı'), findsNothing);
      expect(find.text('Rol'), findsNothing);

      await scrollAndTap(tester, find.text('Personel Ekle'));
      expect(employees.created.single.userId, isNotEmpty);
      expect(access.calls.where((c) => c.startsWith('setOrganizationRole')), isEmpty);
      expect(access.calls.where((c) => c.startsWith('setUserPermissions')), isEmpty);
    });

    testWidgets('tekrar dene yetkileri okur ve matrisi açar', (tester) async {
      final access = FakeAccessRepository()..failNext['getUserPermissions'] = mapHttpError(null, null);
      await pumpAccessApp(tester, client: client, user: ownerUser, location: EmployeesPaths.create, access: access);
      await scrollAndTap(tester, find.text('Mevcut hesaba bağla'));
      await scrollAndTap(tester, find.widgetWithText(DropdownButtonFormField<String>, 'Giriş Hesabı *'));
      await tester.tap(find.textContaining('hasan.aydin').last);
      await tester.pumpAndSettle();
      await scrollAndTap(tester, find.text('Tekrar Dene'));
      expect(find.textContaining('Hesabın rol ve yetkileri alınamadı'), findsNothing);
      expect(access.calls.where((c) => c.startsWith('getUserPermissions')).length, 2);
    });

    testWidgets('kayıt sürerken sayfadan çıkılamaz', (tester) async {
      final gate = Completer<void>();
      final employees = FakeEmployeesRepository()..hold['create'] = gate;
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: EmployeesPaths.create,
        employees: employees,
      );
      await tester.enterText(field('Ad Soyad *'), 'Selin Ak');
      // Düğmede dönen gösterge var: pumpAndSettle yerine tek kare.
      await tester.ensureVisible(find.text('Personel Ekle'));
      await tester.tap(find.text('Personel Ekle'));
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pump();
      expect(find.text('Kaydediliyor, lütfen bitmesini bekle.'), findsOneWidget);
      expect(find.text('Personel Bilgileri'), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('Selin Ak eklendi.'), findsOneWidget);
    });

    testWidgets('uzunluk sınırları sütunlarla aynı; aşırı tutar Türkçe mesajla durur', (tester) async {
      final employees = FakeEmployeesRepository();
      await pumpAccessApp(
        tester,
        client: client,
        user: ownerUser,
        location: EmployeesPaths.create,
        employees: employees,
      );
      await tester.enterText(field('Ad Soyad *'), 'A' * 200);
      await tester.enterText(field('Telefon'), '5' * 60);
      await tester.enterText(field('Aylık Maaş'), '9999999999999');
      await scrollAndTap(tester, find.text('Personel Ekle'));
      expect(tester.widget<TextFormField>(field('Ad Soyad *')).controller!.text.length, 150);
      expect(tester.widget<TextFormField>(field('Telefon')).controller!.text.length, 40);
      expect(find.text('Tutar en fazla 999.999.999.999,99 TL olabilir'), findsOneWidget);
      expect(employees.created, isEmpty);
    });
  });

  test('liste satırı için kısa ücret: birim korunur, kuruş yalnızca varsa', () {
    expect(const EmployeeRecord(id: 'a', fullName: 'A', salary: 85000).wageShortLabel, '85.000 TL/ay');
    expect(
      const EmployeeRecord(id: 'b', fullName: 'B', dailyWage: 2500, salary: 90000).wageShortLabel,
      '2.500 TL/gün',
    );
    expect(const EmployeeRecord(id: 'c', fullName: 'C', dailyWage: 2500.5).wageShortLabel, '2.500,50 TL/gün');
    expect(const EmployeeRecord(id: 'd', fullName: 'D').wageShortLabel, isNull);
  });
}
