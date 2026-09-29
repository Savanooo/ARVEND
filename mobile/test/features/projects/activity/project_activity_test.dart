import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/utils/formatters.dart' show kNbsp;
import 'package:arvend/core/widgets/access_notices.dart';
import 'package:arvend/features/projects/activity/data/project_activity_providers.dart';
import 'package:arvend/features/projects/activity/domain/project_event.dart';

import '../../contract_co/contract_co_test_support.dart' as cc;
import 'project_activity_test_support.dart';

/// Proje Aktivite: Türkçe etiketler, web ile aynı ayrıntı alanları, tutarın
/// yalnızca finans izniyle görünmesi, İstanbul gününe göre gruplama, 403 ve
/// oturum yüklenirken istek atılmaması.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('tr_TR');
  });

  ProjectEvent byId(String id) => kActivityEvents.firstWhere((e) => e.id == id);

  group('alan modeli', () {
    test('etiket: bilinen tip Türkçe, bilinmeyen "Kayıt güncellendi"', () {
      expect(projectEventLabel('collection_received'), 'Tahsilat kaydedildi');
      expect(projectEventLabel('contract_terminated'), 'Sözleşme feshedildi');
      expect(projectEventLabel('yeni_bir_olay_tipi'), 'Kayıt güncellendi');
    });

    test('ayrıntı: tutar yalnızca showMoney ile, durum kodları Türkçe', () {
      final plan = byId('ev2');
      expect(projectEventDetail(plan, currency: 'TRY', showMoney: true), 'Peşinat · 250.000,00${kNbsp}TL');
      expect(projectEventDetail(plan, currency: 'TRY', showMoney: false), 'Peşinat');
      expect(projectEventDetail(byId('ev3'), currency: 'TRY', showMoney: false), '');
      expect(projectEventDetail(byId('ev5'), currency: 'TRY', showMoney: true), 'Ödendi');
      expect(projectEventDetail(byId('ev7'), currency: 'TRY', showMoney: true), 'Kaba inşaat · Devam Ediyor');
      expect(projectEventDetail(byId('ev8'), currency: 'TRY', showMoney: true), 'Mükerrer giriş');
      expect(projectEventDetail(byId('ev9'), currency: 'TRY', showMoney: true), 'Planlandı → Aktif');
      expect(
        projectEventDetail(byId('ev6'), currency: 'TRY', showMoney: true),
        'Toplantı odası cam bölme · 96.000,00${kNbsp}TL',
      );
    });

    test('ton: iptal/red kırmızı, onay/tahsilat yeşil, gönderim mavi', () {
      expect(projectEventTone('expense_voided'), ProjectEventTone.danger);
      expect(projectEventTone('change_order_email_failed'), ProjectEventTone.danger);
      expect(projectEventTone('collection_received'), ProjectEventTone.success);
      expect(projectEventTone('change_order_sent'), ProjectEventTone.info);
      expect(projectEventTone('note_added'), ProjectEventTone.normal);
    });

    test('gün ve saat İstanbul saatiyle (UTC+3), cihaz saat diliminden bağımsız', () {
      expect(projectEventDayKey('2026-09-28T21:30:00Z'), '2026-09-29');
      expect(projectEventClock('2026-09-28T21:30:00Z'), '00:30');
      expect(projectEventDayKey('bozuk'), '');
    });

    test('sağlayıcı en yeniyi üste alır (sunucu ASC döndürür)', () async {
      final container = ProviderContainer(
        overrides: [projectActivityRepositoryProvider.overrideWithValue(FakeActivityRepository())],
      );
      addTearDown(container.dispose);
      final sub = container.listen(projectActivityProvider('p1'), (_, _) {});
      addTearDown(sub.close);
      final events = await container.read(projectActivityProvider('p1').future);
      expect(events.first.id, 'ev10');
      expect(events.last.id, 'ev1');
    });
  });

  group('ekran', () {
    Future<void> pump(WidgetTester tester, Widget app) async {
      await tester.binding.setSurfaceSize(const Size(400, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(app);
      await tester.pumpAndSettle();
    }

    testWidgets('sahip: gün başlıkları, Türkçe etiketler, tutarlar', (tester) async {
      await pump(tester, buildActivityApp(user: activityOwner, repo: FakeActivityRepository()));

      expect(find.text('Aktivite Geçmişi'), findsOneWidget);
      expect(find.text('29 Eylül 2026, Salı'), findsOneWidget);
      expect(find.text('27 Eylül 2026, Pazar'), findsOneWidget);
      expect(find.text('Tahsilat kaydedildi'), findsOneWidget);
      expect(find.text('250.000,00${kNbsp}TL'), findsOneWidget);
      expect(find.text('Kayıt güncellendi'), findsOneWidget);
      expect(find.textContaining('yeni_bir_olay_tipi'), findsNothing);
      expect(find.textContaining('finans görüntüleme yetkisi'), findsNothing);
    });

    testWidgets('finans izni yok: hiçbir tutar yok, açıklama notu var', (tester) async {
      await pump(tester, buildActivityApp(user: activityPm, repo: FakeActivityRepository()));

      expect(find.text('Tahsilat kaydedildi'), findsOneWidget);
      expect(find.textContaining('TL'), findsNothing);
      expect(find.text('Tutarlar yalnızca finans görüntüleme yetkisi olanlara gösterilir.'), findsOneWidget);
    });

    testWidgets('sunucu 403: "Yetkin yok", çökme yok', (tester) async {
      await pump(tester, buildActivityApp(user: activityOwner, repo: FakeActivityRepository(error: activityForbidden)));
      expect(find.byType(NoAccessView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('olay yok: web ile aynı boş metin', (tester) async {
      await pump(tester, buildActivityApp(user: activityOwner, repo: FakeActivityRepository(fixture: const [])));
      expect(find.text('Henüz kayıtlı bir olay yok.'), findsOneWidget);
    });

    testWidgets('oturum yüklenirken istek atılmaz', (tester) async {
      final repo = FakeActivityRepository();
      await tester.pumpWidget(buildActivityApp(auth: PendingAuth.new, repo: repo));
      await tester.pump(const Duration(milliseconds: 100));
      expect(repo.calls, isEmpty);
    });

    testWidgets('projects.read yoksa istek atılmaz', (tester) async {
      final repo = FakeActivityRepository();
      final noRead = cc.buildUser(id: 'field', roleCode: 'field', permissions: {'projects.tasks.read'});
      await pump(tester, buildActivityApp(user: noRead, repo: repo));
      expect(find.byType(NoAccessView), findsOneWidget);
      expect(repo.calls, isEmpty);
    });
  });
}
