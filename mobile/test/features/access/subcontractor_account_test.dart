import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/features/access/access_paths.dart';
import 'package:arvend/features/access/domain/access_models.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/employees/employees_paths.dart';

import 'access_test_support.dart';

/// Taşeron Paneli hesabı (backend 0075) firmanın Kullanıcılar listesinde de
/// görünür, ama taşeron kartından yönetilir: rolü, yetkileri, proje ekibi
/// ve personel kaydı yoktur (sunucu bunları 409 ile reddeder).
const _portalUser = OrgUser(
  id: 'u-taseron',
  username: 'kalip.ali',
  fullName: 'Kalıpçı Ali',
  role: UserRole.kullanici,
  isActive: true,
  organizationRoleCode: 'subcontractor',
  organizationRoleName: 'Taşeron',
);

void main() {
  late ApiClient client;

  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
    client = await unscriptedClient();
  });

  testWidgets('taşeron hesabının detayı: not görünür; rol, proje ve personel bölümleri yok', (tester) async {
    final access = FakeAccessRepository(users: [...sampleUsers(), _portalUser]);
    await pumpAccessApp(
      tester,
      client: client,
      user: ownerUser,
      location: AccessPaths.user('u-taseron'),
      access: access,
    );

    expect(find.byKey(const ValueKey('kullanici-taseron-notu')), findsOneWidget);
    expect(find.text('Rol ve Yetkiler'), findsNothing);
    expect(find.text('Atandığı Projeler'), findsNothing);
    expect(find.text('Personel Kaydı'), findsNothing);
    // Ad ve şifre sıfırlama firma kullanıcısındaki gibi kalır.
    expect(find.text('Kullanıcı Bilgileri'), findsOneWidget);
    expect(find.text('Şifre Sıfırla'), findsOneWidget);
    expect(access.calls, isNot(contains('userProjects u-taseron')));
  });

  testWidgets('personel formu taşeron hesabını bağlanacak hesap olarak sunmaz', (tester) async {
    final access = FakeAccessRepository(users: [...sampleUsers(), _portalUser]);
    await pumpAccessApp(tester, client: client, user: ownerUser, location: EmployeesPaths.create, access: access);

    await scrollAndTap(tester, find.text('Mevcut hesaba bağla'));
    await scrollAndTap(tester, find.widgetWithText(DropdownButtonFormField<String>, 'Giriş Hesabı *'));
    expect(find.textContaining('hasan.aydin'), findsWidgets);
    expect(find.textContaining('kalip.ali'), findsNothing);
  });
}
