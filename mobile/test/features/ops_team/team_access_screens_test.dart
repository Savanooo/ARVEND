import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/ops_team/domain/project_access.dart';
import 'package:arvend/features/projects/ops_team/ops_team_routes.dart';
import 'package:arvend/features/projects/ops_team/presentation/widgets/ops_common.dart' show kAccessNoUserListText;

import 'ops_team_test_support.dart';

/// Proje Ekibi (personel roster'ı) ve Proje Erişimi (uygulama
/// kullanıcıları) ekranları + proje detayına gömülü bölüm tanımları.
void main() {
  Future<FakeOpsTeamRepository> pump(
    WidgetTester tester, {
    required String location,
    User? user,
    String projectStatus = 'active',
    FakeOpsTeamRepository? repo,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(420, 1600);
    addTearDown(tester.view.reset);
    final r = repo ?? FakeOpsTeamRepository();
    await tester.pumpWidget(buildOpsApp(
      user: user ?? opsOwnerUser,
      repo: r,
      initialLocation: location,
      projectStatus: projectStatus,
    ));
    await tester.pumpAndSettle();
    return r;
  }

  Future<void> pickDropdown(WidgetTester tester, Key key, String item) async {
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item).last);
    await tester.pumpAndSettle();
  }

  group('Proje Ekibi', () {
    testWidgets('sahip: aktif ekip, katlanır geçmiş, ekle/çıkar düğmeleri', (tester) async {
      await pump(tester, location: teamPath(kProjectId));
      expect(find.text('AKTİF EKİP (4)'), findsOneWidget);
      expect(find.text('Ahmet Yılmaz'), findsOneWidget);
      expect(find.text('Şantiye Şefi · Başlangıç 01.08.2026'), findsOneWidget);
      expect(find.text('Haftada iki gün sahada'), findsOneWidget);
      expect(find.text('Ekibe Ekle'), findsOneWidget);
      expect(find.byTooltip('Ekipten Çıkar'), findsNWidgets(4));

      // Geçmiş ekip web'deki <details> gibi kapalı başlar.
      expect(find.text('GEÇMİŞ EKİP (2)'), findsOneWidget);
      expect(find.text('Hasan Çelik'), findsNothing);
      await tester.tap(find.text('GEÇMİŞ EKİP (2)'));
      await tester.pumpAndSettle();
      expect(find.text('Hasan Çelik'), findsOneWidget);
      expect(find.text('Kalıpçı · ayrıldı 15.09.2026'), findsOneWidget);
    });

    testWidgets('salt-okunur: ekle/çıkar yok', (tester) async {
      await pump(tester, location: teamPath(kProjectId), user: opsReadOnlyUser);
      expect(find.text('Ekibe Ekle'), findsNothing);
      expect(find.byTooltip('Ekipten Çıkar'), findsNothing);
      expect(find.textContaining('Proje ekibini yalnızca görüntüleyebilirsin'), findsOneWidget);
    });

    testWidgets('Proje Yöneticisi (operations.manage, employees.read YOK): ekleyebilir ve çıkarabilir', (
      tester,
    ) async {
      // Regresyon: seçici GET /employees (employees.read) istediği için
      // Proje Yöneticisi/Saha ekibe hiç ekleyemiyordu; artık projenin
      // ücretsiz assignees ucundan gelir.
      final repo = await pump(tester, location: teamPath(kProjectId), user: opsManagerUser);
      expect(find.byTooltip('Ekipten Çıkar'), findsNWidgets(4));
      expect(repo.calls.where((c) => c.startsWith('employees')), isEmpty);
      await tester.tap(find.text('Ekibe Ekle'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('employees:$kProjectId'));
      await pickDropdown(tester, const ValueKey('team-employee'), 'Zeynep Arslan — Mimar');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Ekibe Ekle'));
      await tester.pumpAndSettle();
      expect(repo.addedMembers.single.employeeId, 'e7');
    });

    testWidgets('ekibe ekle: projeyi göremeyen hesap için erişim uyarısı', (tester) async {
      await pump(tester, location: teamPath(kProjectId));
      await tester.tap(find.text('Ekibe Ekle'));
      await tester.pumpAndSettle();
      await pickDropdown(tester, const ValueKey('team-employee'), 'Selim Ok — Usta (proje erişimi yok)');
      expect(find.textContaining('ekibe eklemek erişim vermez'), findsOneWidget);
    });

    testWidgets('kilitli proje: ekle/çıkar yok', (tester) async {
      await pump(tester, location: teamPath(kProjectId), projectStatus: 'completed');
      expect(find.text('Ekibe Ekle'), findsNothing);
      expect(find.byTooltip('Ekipten Çıkar'), findsNothing);
      expect(find.textContaining('Proje tamamlandı veya iptal edildi'), findsOneWidget);
    });

    testWidgets('izni olmayan: istek atılmaz', (tester) async {
      final repo = await pump(tester, location: teamPath(kProjectId), user: opsNoAccessUser);
      expect(find.text('Yetkin yok'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('ekibe ekle: aktif üyeler seçicide yok, geçmiş üye yeniden eklenebilir', (tester) async {
      final repo = await pump(tester, location: teamPath(kProjectId));
      await tester.tap(find.text('Ekibe Ekle'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('team-employee')));
      await tester.pumpAndSettle();
      expect(find.text('Zeynep Arslan — Mimar'), findsWidgets);
      expect(find.text('Hasan Çelik — Kalıpçı'), findsWidgets);
      expect(find.text('Ahmet Yılmaz — İnşaat Mühendisi'), findsNothing);
      await tester.tap(find.text('Zeynep Arslan — Mimar').last);
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('team-role-title')), ' Proje Mimarı ');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Ekibe Ekle'));
      await tester.pumpAndSettle();

      final input = repo.addedMembers.single;
      expect(input.employeeId, 'e7');
      expect(input.roleTitle, 'Proje Mimarı');
      expect(input.startDate, isNull);
      expect(find.text('AKTİF EKİP (5)'), findsOneWidget);
      expect(find.text('Zeynep Arslan ekibe eklendi.'), findsOneWidget);
    });

    testWidgets('ekibe ekle: personel seçilmeden gönderilmez', (tester) async {
      final repo = await pump(tester, location: teamPath(kProjectId));
      await tester.tap(find.text('Ekibe Ekle'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Ekibe Ekle'));
      await tester.pumpAndSettle();
      expect(find.text('Personel seç'), findsWidgets);
      expect(repo.addedMembers, isEmpty);
    });

    testWidgets('ekibe ekle: 409 mesajı formda gösterilir', (tester) async {
      final repo = FakeOpsTeamRepository()..writeError = conflictWith('bu personel zaten projenin aktif ekibinde');
      await pump(tester, location: teamPath(kProjectId), repo: repo);
      await tester.tap(find.text('Ekibe Ekle'));
      await tester.pumpAndSettle();
      await pickDropdown(tester, const ValueKey('team-employee'), 'Burak Koç — Elektrik Teknikeri');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Ekibe Ekle'));
      await tester.pumpAndSettle();
      expect(find.text('bu personel zaten projenin aktif ekibinde'), findsOneWidget);
      // Sayfa açık kalır.
      expect(find.widgetWithText(ElevatedButton, 'Ekibe Ekle'), findsOneWidget);
    });

    testWidgets('personel listesi 403: formda not, çökme yok', (tester) async {
      final repo = FakeOpsTeamRepository()..employeesError = forbidden;
      await pump(tester, location: teamPath(kProjectId), repo: repo);
      await tester.tap(find.text('Ekibe Ekle'));
      await tester.pumpAndSettle();
      expect(find.text('Personel listesini görüntüleme yetkin yok.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ekipten çıkar: onaydan sonra geçmişe taşınır', (tester) async {
      final repo = await pump(tester, location: teamPath(kProjectId));
      await tester.tap(find.byTooltip('Ekipten Çıkar').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Can Öztürk ekipten çıkarılsın mı?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Ekipten Çıkar'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('endMembership:m4'));
      expect(find.text('AKTİF EKİP (3)'), findsOneWidget);
      expect(find.text('GEÇMİŞ EKİP (3)'), findsOneWidget);
    });

    testWidgets('ekipten çıkar: vazgeçilirse istek yok', (tester) async {
      final repo = await pump(tester, location: teamPath(kProjectId));
      await tester.tap(find.byTooltip('Ekipten Çıkar').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(repo.calls.where((c) => c.startsWith('endMembership')), isEmpty);
    });
  });

  group('Proje Erişimi', () {
    testWidgets('sahip: kullanıcılar, rol rozetleri, pasif, "Erişim Ver"', (tester) async {
      await pump(tester, location: accessPath(kProjectId));
      expect(find.textContaining('Sahip/Yönetici rolündeki kullanıcılar'), findsWidgets);
      expect(find.text('Selin Aydın'), findsOneWidget);
      expect(find.text('selin.aydin · Proje Yöneticisi'), findsOneWidget);
      expect(find.text('Görüntüleyici'), findsOneWidget);
      expect(find.text('Üye'), findsNWidgets(2));
      expect(find.text('Pasif'), findsOneWidget);
      expect(find.text('Erişim Ver'), findsOneWidget);
    });

    testWidgets('access.manage var ama Yönetici değil: "Erişim Ver" yok, mevcut erişim düzenlenebilir', (
      tester,
    ) async {
      // Regresyon: "Erişim Ver" seçicisi GET /users (requireAdmin +
      // organization.users.read) ister; kişiye özel access.manage alan
      // kullanıcı hiç tamamlanamayan bir forma gidiyordu.
      final user = buildOpsUser({...kOpsAll, 'organization.users.read'});
      await pump(tester, location: accessPath(kProjectId), user: user);
      expect(find.text('Erişim Ver'), findsNothing);
      expect(find.text(kAccessNoUserListText), findsOneWidget);
      await tester.tap(find.text('Murat Er'));
      await tester.pumpAndSettle();
      expect(find.text('Erişimi Kaldır'), findsOneWidget);
    });

    testWidgets('proje yöneticisi (yalnızca görüntüleme): düzenleme yok', (tester) async {
      await pump(tester, location: accessPath(kProjectId), user: opsManagerUser);
      expect(find.text('Erişim Ver'), findsNothing);
      expect(find.textContaining('Proje erişimini yalnızca görüntüleyebilirsin'), findsOneWidget);
      await tester.tap(find.text('Murat Er'));
      await tester.pumpAndSettle();
      expect(find.text('Proje rolü'), findsNothing);
    });

    testWidgets('erişim ver: yalnızca aktif ve atanmamış kullanıcılar, varsayılan rol Üye', (tester) async {
      final repo = await pump(tester, location: accessPath(kProjectId));
      await tester.tap(find.text('Erişim Ver'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('access-user')));
      await tester.pumpAndSettle();
      expect(find.text('Elif Şen — Saha'), findsWidgets);
      expect(find.text('Taha Yetişözen — Sahip (Owner)'), findsWidgets);
      expect(find.text('Gül Ay — Saha'), findsNothing); // pasif
      expect(find.text('Selin Aydın — Proje Yöneticisi'), findsNothing); // zaten erişimi var
      await tester.tap(find.text('Elif Şen — Saha').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Erişim Ver'));
      await tester.pumpAndSettle();
      expect(repo.grants, [('u5', ProjectRole.member)]);
      expect(find.text('Elif Şen kullanıcısına erişim verildi.'), findsOneWidget);
      expect(find.text('Elif Şen'), findsOneWidget);
    });

    testWidgets('erişim ver: rol seçilebilir', (tester) async {
      final repo = await pump(tester, location: accessPath(kProjectId));
      await tester.tap(find.text('Erişim Ver'));
      await tester.pumpAndSettle();
      await pickDropdown(tester, const ValueKey('access-user'), 'Kerem Ak — Finans');
      await tester.tap(find.text('Görüntüleyici').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Erişim Ver'));
      await tester.pumpAndSettle();
      expect(repo.grants, [('u6', ProjectRole.viewer)]);
    });

    testWidgets('kullanıcı listesi 403: formda not', (tester) async {
      final repo = FakeOpsTeamRepository()..orgUsersError = forbidden;
      await pump(tester, location: accessPath(kProjectId), repo: repo);
      await tester.tap(find.text('Erişim Ver'));
      await tester.pumpAndSettle();
      expect(find.text('Kullanıcı listesini görüntüleme yetkin yok.'), findsOneWidget);
    });

    testWidgets('rol değiştir', (tester) async {
      final repo = await pump(tester, location: accessPath(kProjectId));
      await tester.tap(find.text('Murat Er'));
      await tester.pumpAndSettle();
      // Aynı rol seçiliyken Kaydet kapalı.
      final save = find.widgetWithText(ElevatedButton, 'Kaydet');
      expect(tester.widget<ElevatedButton>(save).onPressed, isNull);
      await tester.tap(find.text('Proje Yöneticisi').last);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(repo.roleChanges, [('u3', ProjectRole.projectManager)]);
      expect(find.text('Murat Er kullanıcısının proje rolü güncellendi.'), findsOneWidget);
    });

    testWidgets('erişimi kaldır: onaylı', (tester) async {
      final repo = await pump(tester, location: accessPath(kProjectId));
      await tester.tap(find.text('Deniz Kara'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Erişimi Kaldır'));
      await tester.pumpAndSettle();
      expect(find.text('Deniz Kara adlı kullanıcının bu projeye erişimi kaldırılsın mı?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Kaldır'));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('revoke:u2'));
      expect(find.text('Deniz Kara'), findsNothing);
    });

    testWidgets('sunucu 403: "Yetkin yok"', (tester) async {
      final repo = FakeOpsTeamRepository()..accessError = forbidden;
      await pump(tester, location: accessPath(kProjectId), repo: repo);
      expect(find.text('Yetkin yok'), findsOneWidget);
    });

    testWidgets('boş liste', (tester) async {
      await pump(tester, location: accessPath(kProjectId), repo: FakeOpsTeamRepository(access: const []));
      expect(find.text('Bu projeye açıkça atanmış kullanıcı yok.'), findsOneWidget);
    });

    testWidgets('proje kilidi erişimi etkilemez', (tester) async {
      await pump(tester, location: accessPath(kProjectId), projectStatus: 'completed');
      expect(find.text('Erişim Ver'), findsOneWidget);
    });
  });

  group('Proje detayına gömülü bölümler', () {
    testWidgets('sahip üç alt görünümü görür; ?alt=ekip ekibi açar', (tester) async {
      await pump(tester, location: '/projeler/$kProjectId?alt=ekip');
      expect(find.byKey(const ValueKey('proje-alt-planlama')), findsOneWidget);
      expect(find.byKey(const ValueKey('proje-alt-erisim')), findsOneWidget);
      expect(find.text('AKTİF EKİP (4)'), findsOneWidget);
      // Gömülü gövdeden detaya geçiş gerçek rotalarla çalışır.
      await tester.tap(find.byKey(const ValueKey('proje-alt-planlama')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kaba İnşaat'));
      await tester.pumpAndSettle();
      expect(find.text('Bilgiler'), findsOneWidget);
    });

    testWidgets('erişim izni olmayan: "Erişim" çipi yok', (tester) async {
      final user = buildOpsUser({'projects.read', 'projects.operations.read'});
      await pump(tester, location: '/projeler/$kProjectId', user: user);
      expect(find.byKey(const ValueKey('proje-alt-erisim')), findsNothing);
      expect(find.byKey(const ValueKey('proje-alt-ekip')), findsOneWidget);
    });

    testWidgets('kilit bilgisi proje kaydından gelir', (tester) async {
      await pump(tester, location: '/projeler/$kProjectId?alt=planlama', projectStatus: 'cancelled');
      expect(find.text('Aşama Ekle'), findsNothing);
      expect(find.textContaining('Proje tamamlandı veya iptal edildi'), findsOneWidget);
    });

    test('bölüm tanımları: grup, alt, izinler', () {
      expect([for (final s in opsTeamSections) '${s.group}/${s.alt}'], [
        'operasyon/planlama',
        'operasyon/ekip',
        'operasyon/erisim',
      ]);
      expect(opsTeamSections[0].readPermission, 'projects.operations.read');
      expect(opsTeamSections[0].managePermission, 'projects.operations.manage');
      expect(opsTeamSections[2].readPermission, 'projects.access.read');
      expect(opsTeamSections[2].managePermission, 'projects.access.manage');
      expect(opsTeamSections[1].location('p 1'), '/projeler/p%201/ekip');
      expect(opsTeamSections[0].visibleFor(opsNoAccessUser), isFalse);
      expect(opsTeamSections[2].visibleFor(opsReadOnlyUser), isTrue);
    });
  });
}
