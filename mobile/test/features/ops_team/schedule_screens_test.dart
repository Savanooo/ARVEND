import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/ops_team/domain/schedule_item.dart';
import 'package:arvend/features/projects/ops_team/ops_team_routes.dart';

import 'ops_team_test_support.dart';

/// Planlama (iş programı) ekranları: liste/zaman çizelgesi, gecikme vurgusu,
/// izin/kilit kapıları, aşama ekle/düzenle, durum aksiyonları ve hata
/// (403/409) davranışı. Sahte depo -- ağ yok.
void main() {
  Future<FakeOpsTeamRepository> pump(
    WidgetTester tester, {
    required String location,
    User? user,
    String projectStatus = 'active',
    FakeOpsTeamRepository? repo,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(400, 1400);
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

  group('Planlama listesi', () {
    testWidgets('sahip: özet, zaman çizelgesi, gecikme ve "Aşama Ekle"', (tester) async {
      await pump(tester, location: schedulePath(kProjectId));

      expect(find.text('6 aşama'), findsOneWidget);
      expect(find.text('1 geciken'), findsOneWidget);
      expect(find.text('Aşama Ekle'), findsOneWidget);
      expect(find.text('Kaba İnşaat'), findsOneWidget);
      // Yalnızca bitişi geçmiş AÇIK aşama gecikmiş sayılır (Kaba İnşaat,
      // bitiş 24.09 -> 5 gün); tamamlanmış/iptal/ileri tarihliler değil.
      expect(find.text('Gecikti · bitiş 5 gün önce geçti'), findsOneWidget);
      expect(find.text('3/8 görev'), findsOneWidget);
      expect(find.text('Tarih belirtilmedi'), findsOneWidget);
      expect(find.text('Görev ilerlemesi'), findsOneWidget);
      expect(find.text('13/20 görev'), findsOneWidget);
    });

    testWidgets('salt-okunur: ekleme yok, bilgi notu var', (tester) async {
      await pump(tester, location: schedulePath(kProjectId), user: opsReadOnlyUser);
      expect(find.text('Aşama Ekle'), findsNothing);
      expect(find.textContaining('Planlamayı yalnızca görüntüleyebilirsin'), findsOneWidget);
      expect(find.text('Kaba İnşaat'), findsOneWidget);
    });

    testWidgets('tamamlanmış projede yeni aşama eklenemez', (tester) async {
      await pump(tester, location: schedulePath(kProjectId), projectStatus: 'completed');
      expect(find.text('Aşama Ekle'), findsNothing);
      expect(find.textContaining('Proje tamamlandı veya iptal edildi'), findsOneWidget);
    });

    testWidgets('izni olmayan: API çağrılmadan "Yetkin yok"', (tester) async {
      final repo = await pump(tester, location: schedulePath(kProjectId), user: opsNoAccessUser);
      expect(find.text('Yetkin yok'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('sunucu 403 dönerse çökmez, "Yetkin yok" gösterir', (tester) async {
      final repo = FakeOpsTeamRepository()..scheduleError = forbidden;
      await pump(tester, location: schedulePath(kProjectId), repo: repo);
      expect(find.text('Yetkin yok'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('boş plan', (tester) async {
      await pump(tester, location: schedulePath(kProjectId), repo: FakeOpsTeamRepository(schedule: const []));
      expect(find.text('Henüz planlama aşaması yok.'), findsOneWidget);
    });
  });

  group('Aşama ekle / düzenle', () {
    testWidgets('yeni aşama listenin sonuna eklenir (sort_order = aşama sayısı)', (tester) async {
      final repo = await pump(tester, location: schedulePath(kProjectId));
      await tester.tap(find.text('Aşama Ekle'));
      await tester.pumpAndSettle();
      expect(find.text('Yeni Aşama'), findsOneWidget);
      // Yeni aşamada durum sorulmaz (web ile aynı -- "Planlandı" açılır).
      expect(find.text('Durum'), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('schedule-name')), '  Çevre Düzenlemesi ');
      await tester.enterText(find.byKey(const ValueKey('schedule-description')), 'Bahçe ve otopark');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Aşama Ekle'));
      await tester.pumpAndSettle();

      expect(repo.createdSchedule, [
        const ScheduleItemInput(
          name: 'Çevre Düzenlemesi',
          description: 'Bahçe ve otopark',
          status: ScheduleStatus.planned,
          sortOrder: 6,
        ),
      ]);
      // Listeye dönüldü ve liste tazelendi.
      expect(find.text('Çevre Düzenlemesi'), findsOneWidget);
      expect(find.text('7 aşama'), findsOneWidget);
    });

    testWidgets('ad zorunlu', (tester) async {
      final repo = await pump(tester, location: scheduleNewPath(kProjectId));
      await tester.tap(find.widgetWithText(ElevatedButton, 'Aşama Ekle'));
      await tester.pumpAndSettle();
      expect(find.text('Aşama adı zorunludur'), findsOneWidget);
      expect(repo.createdSchedule, isEmpty);
    });

    testWidgets('bitiş başlangıçtan önce olamaz', (tester) async {
      final repo = await pump(tester, location: scheduleItemEditPath(kProjectId, 's3'));
      // Başlangıcı 28.09'a al (bitiş 24.09 kalıyor).
      await tester.tap(find.byKey(const ValueKey('schedule-start')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('28'));
      await tester.tap(find.byType(TextButton).last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
      await tester.pumpAndSettle();
      expect(find.text('Bitiş tarihi başlangıçtan önce olamaz.'), findsOneWidget);
      expect(repo.updatedSchedule, isEmpty);
    });

    testWidgets('düzenleme: alanlar dolu gelir, sıra korunur, durum seçilebilir', (tester) async {
      final repo = await pump(tester, location: scheduleItemEditPath(kProjectId, 's3'));
      expect(find.text('Aşamayı Düzenle'), findsOneWidget);
      expect(find.text('Kaba İnşaat'), findsOneWidget);
      expect(find.text('01.09.2026'), findsOneWidget);
      expect(find.text('24.09.2026'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Tamamlandı'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Kaydet'));
      await tester.pumpAndSettle();

      expect(repo.updatedSchedule.single.$1, 's3');
      expect(
        repo.updatedSchedule.single.$2,
        const ScheduleItemInput(
          name: 'Kaba İnşaat',
          description: 'Betonarme karkas, döşemeler ve perde duvarlar',
          startDate: '2026-09-01',
          endDate: '2026-09-24',
          status: ScheduleStatus.completed,
          sortOrder: 2,
        ),
      );
    });

    testWidgets('yazma izni olmayan form açamaz', (tester) async {
      await pump(tester, location: scheduleNewPath(kProjectId), user: opsReadOnlyUser);
      expect(find.text('Yetkin yok'), findsOneWidget);
      expect(find.byKey(const ValueKey('schedule-name')), findsNothing);
    });
  });

  group('Aşama detayı', () {
    testWidgets('gecikmiş aşama: uyarı + "Tamamla" onayla, diğer alanlar korunur', (tester) async {
      final repo = await pump(tester, location: scheduleItemPath(kProjectId, 's3'));
      expect(find.text('Gecikti'), findsOneWidget);
      expect(find.textContaining('Bitiş tarihi 5 gün önce geçti'), findsOneWidget);
      expect(find.text('3/8 tamamlandı'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Tamamla'));
      await tester.pumpAndSettle();
      expect(find.text('Aşamayı Tamamla'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Tamamla'));
      await tester.pumpAndSettle();

      final (id, input) = repo.updatedSchedule.single;
      expect(id, 's3');
      expect(input.status, ScheduleStatus.completed);
      expect(input.name, 'Kaba İnşaat');
      expect(input.startDate, '2026-09-01');
      expect(input.endDate, '2026-09-24');
      expect(input.sortOrder, 2);
      // Tamamlanınca gecikme kalkar.
      expect(find.text('Gecikti'), findsNothing);
    });

    testWidgets('vazgeçilirse istek atılmaz', (tester) async {
      final repo = await pump(tester, location: scheduleItemPath(kProjectId, 's3'));
      await tester.tap(find.widgetWithText(ElevatedButton, 'Tamamla'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vazgeç'));
      await tester.pumpAndSettle();
      expect(repo.updatedSchedule, isEmpty);
    });

    testWidgets('planlanan aşama: "Başlat" ve "İptal Et" (silme yok)', (tester) async {
      final repo = await pump(tester, location: scheduleItemPath(kProjectId, 's4'));
      expect(find.text('Başlat'), findsOneWidget);
      expect(find.text('Sil'), findsNothing);
      await tester.tap(find.widgetWithText(OutlinedButton, 'İptal Et'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Aşama silinmez'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'İptal Et'));
      await tester.pumpAndSettle();
      expect(repo.updatedSchedule.single.$2.status, ScheduleStatus.cancelled);
    });

    testWidgets('salt-okunur: aksiyon ve düzenle yok', (tester) async {
      await pump(tester, location: scheduleItemPath(kProjectId, 's3'), user: opsReadOnlyUser);
      expect(find.text('Tamamla'), findsNothing);
      expect(find.byTooltip('Düzenle'), findsNothing);
      expect(find.text('Kaba İnşaat'), findsWidgets);
    });

    testWidgets('kilitli projede aksiyon yok', (tester) async {
      await pump(tester, location: scheduleItemPath(kProjectId, 's3'), projectStatus: 'cancelled');
      expect(find.text('Tamamla'), findsNothing);
      expect(find.textContaining('Proje tamamlandı veya iptal edildi'), findsOneWidget);
    });

    testWidgets('409: mesaj gösterilir ve liste yeniden çekilir', (tester) async {
      final repo = FakeOpsTeamRepository()
        ..writeError = conflictWith('proje kilitli: tamamlanmış projede değişiklik yapılamaz');
      await pump(tester, location: scheduleItemPath(kProjectId, 's4'), repo: repo);
      final before = repo.calls.where((c) => c.startsWith('schedule:')).length;
      await tester.tap(find.widgetWithText(ElevatedButton, 'Başlat'));
      await tester.pumpAndSettle();
      expect(find.text('proje kilitli: tamamlanmış projede değişiklik yapılamaz'), findsOneWidget);
      expect(repo.calls.where((c) => c.startsWith('schedule:')).length, greaterThan(before));
      expect(tester.takeException(), isNull);
    });

    testWidgets('bilinmeyen aşama', (tester) async {
      await pump(tester, location: scheduleItemPath(kProjectId, 'yok'));
      expect(find.text('Aşama bulunamadı.'), findsOneWidget);
    });
  });
}
