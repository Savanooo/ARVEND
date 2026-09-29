import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/features/offers/history/data/offer_history_repository.dart';
import 'package:arvend/features/offers/history/domain/offer_history.dart';
import 'package:arvend/features/offers/history/offer_history_routes.dart';
import 'package:arvend/features/offers/history/presentation/offer_history_section.dart' show kOfferHistoryNoAccessText;

import '../../test_utils/fake_api_client.dart';
import 'offer_history_test_support.dart';

/// Teklif geçmişi: web `ActivityTimeline.tsx` ile aynı metinler (revizyon
/// numarası + Türkçe belirtme eki), uç sözleşmesi, teklif detayına gömülü
/// bölüm ve tam ekran.
void main() {
  OfferEvent ev(String type, {String? rev, Map<String, dynamic> metadata = const {}}) =>
      OfferEvent(id: 'x', eventType: type, revisionId: rev, metadata: metadata, createdAt: '2026-09-10T07:30:00Z');

  group('Olay metinleri', () {
    test('Türkçe belirtme eki okunuşa göre', () {
      expect([for (var n = 0; n <= 10; n++) turkishAccusativeSuffix(n)],
          ['ı', 'i', 'yi', 'ü', 'ü', 'i', 'yı', 'yi', 'i', 'u', 'u']);
      expect(turkishAccusativeSuffix(20), 'yi');
      expect(turkishAccusativeSuffix(30), 'u');
      expect(turkishAccusativeSuffix(40), 'ı');
      expect(turkishAccusativeSuffix(12), 'yi');
      expect(turkishAccusativeSuffix(100), 'ı');
    });

    test('revizyonlu metinler', () {
      expect(offerEventLabel(ev('customer_viewed'), 2), "Müşteri Revizyon 2'yi görüntüledi");
      expect(offerEventLabel(ev('customer_accepted'), 3), "Müşteri Revizyon 3'ü kabul etti");
      expect(offerEventLabel(ev('customer_rejected'), 10), "Müşteri Revizyon 10'u reddetti");
      expect(offerEventLabel(ev('revision_sent'), 1), 'Revizyon 1 müşteriye gönderildi');
      expect(offerEventLabel(ev('share_link_created'), 1), 'Revizyon 1 için paylaşım linki oluşturuldu');
      expect(offerEventLabel(ev('email_failed'), 2), 'Revizyon 2 e-postası gönderilemedi');
      expect(offerEventLabel(ev('offer_updated'), 2), 'Revizyon 2 düzenlendi');
    });

    test('revizyonsuz metinler ortak haritadan', () {
      expect(offerEventLabel(ev('customer_viewed'), null), 'Müşteri teklifi görüntüledi');
      expect(offerEventLabel(ev('offer_created'), 4), 'Teklif oluşturuldu');
      expect(offerEventLabel(ev('offer_cancelled'), null), 'Teklif arşivlendi / iptal edildi');
    });

    test('paylaşım linki iptali nedeni', () {
      final byRevision = ev('share_link_revoked', metadata: {'reason': 'revision_sent'});
      expect(offerEventLabel(byRevision, 1), 'Revizyon 1 linki, yeni revizyon gönderildiği için iptal edildi');
      expect(offerEventLabel(byRevision, null), 'Eski paylaşım linki iptal edildi');
      expect(offerEventLabel(ev('share_link_revoked'), 1), 'Revizyon 1 paylaşım linki iptal edildi');
    });

    test('projeye dönüştürme ve bilinmeyen tip', () {
      expect(offerEventLabel(ev('project_created', metadata: {'project_no': 'PRJ-7'}), null),
          'Projeye dönüştürüldü (PRJ-7)');
      expect(offerEventLabel(ev('project_created'), null), 'Teklif projeye dönüştürüldü');
      expect(offerEventLabel(ev('gelecekte_eklenen'), 1), 'Kayıt güncellendi');
    });

    test('tonlar', () {
      expect(offerEventTone('customer_accepted'), OfferEventTone.success);
      expect(offerEventTone('email_failed'), OfferEventTone.danger);
      expect(offerEventTone('share_link_revoked'), OfferEventTone.muted);
      expect(offerEventTone('customer_viewed'), OfferEventTone.info);
      expect(offerEventTone('offer_created'), OfferEventTone.normal);
    });

    test('saatler cihazdan bağımsız İstanbul saati', () {
      expect(offerShortStamp('2026-09-10T21:30:00Z'), '11.09 00:30');
      expect(offerFullStamp('2026-09-10T07:30:00Z'), '10.09.2026 10:30');
      expect(offerShortStamp('bozuk'), '-');
    });
  });

  group('OfferHistoryRepository', () {
    test('üç uç paralel çağrılır, revizyon numaraları eşlenir', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/offers/o1/events': [
          (status: 200, body: {
            'events': [
              {
                'id': 'e1',
                'revision_id': 'r2',
                'event_type': 'customer_viewed',
                'user_id': null,
                'created_at': '2026-09-11T06:12:00Z',
              },
              {
                'id': 'e2',
                'revision_id': null,
                'event_type': 'project_created',
                'user_id': 'u1',
                'metadata': {'project_no': 'PRJ-1'},
                'created_at': '2026-09-12T06:12:00Z',
              },
            ],
          }),
        ],
        '/offers/o1/email-logs': [
          (status: 200, body: {
            'email_logs': [
              {
                'id': 'm1',
                'revision_id': 'r2',
                'recipient': 'a@b.com',
                'subject': 'Teklif',
                'status': 'failed',
                'error_message': 'smtp',
                'sent_by': 'u1',
                'sent_at': '2026-09-11T06:00:00Z',
              },
            ],
          }),
        ],
        '/offers/o1/revisions': [
          (status: 200, body: {
            'revisions': [
              {'id': 'r1', 'revision_no': 1, 'grand_total': 100},
              {'id': 'r2', 'revision_no': 2, 'grand_total': 120},
            ],
          }),
        ],
      });
      final repo = OfferHistoryRepository(await buildFakeApiClient(adapter));
      final h = await repo.history('o1');
      expect(adapter.calls.toSet(), {'/offers/o1/events', '/offers/o1/email-logs', '/offers/o1/revisions'});
      expect(h.events.length, 2);
      expect(h.events[1].metadata['project_no'], 'PRJ-1');
      expect(h.revisionNoOf('r2'), 2);
      expect(h.revisionNoOf(null), isNull);
      expect(h.emailLogs.single.isSent, isFalse);
      expect(h.emailLogs.single.errorMessage, 'smtp');
      expect(h.views.length, 1);
    });
  });

  group('Teklif detayındaki bölüm', () {
    Future<FakeOfferHistoryRepository> pump(WidgetTester tester, {FakeOfferHistoryRepository? repo, String? location}) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(420, 2400);
      addTearDown(tester.view.reset);
      final r = repo ?? FakeOfferHistoryRepository();
      await tester.pumpWidget(buildOfferHistoryApp(repo: r, initialLocation: location ?? '/teklifler/$kOfferId'));
      await tester.pumpAndSettle();
      return r;
    }

    testWidgets('son 5 olay, görüntülenme özeti ve mail geçmişi', (tester) async {
      await pump(tester);
      expect(find.text('Aktivite / Zaman Çizelgesi'), findsOneWidget);
      expect(find.text('Tümünü Gör (15)'), findsOneWidget);
      expect(find.text('Son 5 olay gösteriliyor.'), findsOneWidget);
      expect(find.text('Projeye dönüştürüldü (PRJ-2026-0007)'), findsOneWidget);
      expect(find.text("Müşteri Revizyon 2'yi kabul etti"), findsOneWidget);
      // Önizlemede yok (ilk olay).
      expect(find.text('Teklif oluşturuldu'), findsNothing);
      expect(find.textContaining('3 görüntülenme'), findsOneWidget);
      expect(find.text('Mail Geçmişi'), findsOneWidget);
      expect(find.text('Başarısız'), findsOneWidget);
      expect(find.text('Gönderildi'), findsNWidgets(2));
      expect(find.text('SMTP sunucusuna bağlanılamadı (zaman aşımı)'), findsOneWidget);
      expect(find.text('Teklif TKL-2026-0031 · Revizyon 2 · 16.09.2026 10:10'), findsOneWidget);
    });

    testWidgets('"Tümünü Gör" tam ekranı açar; sekmeler', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Tümünü Gör (15)'));
      await tester.pumpAndSettle();
      expect(find.text('Teklif Geçmişi'), findsOneWidget);
      expect(find.text('Teklif oluşturuldu'), findsOneWidget);
      expect(find.text('10.09 10:30'), findsOneWidget);
      expect(find.text('Revizyon 1 linki, yeni revizyon gönderildiği için iptal edildi'), findsOneWidget);
      expect(find.text('Mail Geçmişi (3)'), findsOneWidget);
      await tester.tap(find.text('Mail Geçmişi (3)'));
      await tester.pumpAndSettle();
      expect(find.text('info@modayapi.com.tr'), findsOneWidget);
      expect(find.text('Teklif oluşturuldu'), findsNothing);
    });

    testWidgets('?sekme=eposta mail geçmişiyle açılır', (tester) async {
      await pump(tester, location: offerHistoryPath(kOfferId, emails: true));
      expect(find.text('info@modayapi.com.tr'), findsOneWidget);
      expect(find.text('Teklif oluşturuldu'), findsNothing);
    });

    testWidgets('az olayda "Tümünü Gör" yok; e-posta yoksa Mail Geçmişi gizli', (tester) async {
      await pump(
        tester,
        repo: FakeOfferHistoryRepository(eventItems: kOfferEventFixtures.take(3).toList(), emailItems: const []),
      );
      expect(find.textContaining('Tümünü Gör'), findsNothing);
      expect(find.text('Son 5 olay gösteriliyor.'), findsNothing);
      expect(find.text('Mail Geçmişi'), findsNothing);
      expect(find.text('Teklif oluşturuldu'), findsOneWidget);
    });

    testWidgets('3ten fazla e-posta: son 3 + "Tümünü Gör" mail sekmesini açar', (tester) async {
      const extra = OfferEmailLog(
        id: 'ml0',
        revisionId: 'r1',
        recipient: 'eski@modayapi.com.tr',
        subject: 'Teklif TKL-2026-0031',
        status: OfferEmailLog.statusSent,
        sentAt: '2026-09-09T08:00:00Z',
      );
      await pump(tester, repo: FakeOfferHistoryRepository(emailItems: [...kOfferEmailFixtures, extra]));
      expect(find.text('eski@modayapi.com.tr'), findsNothing);
      await tester.tap(find.text('Tümünü Gör (4)'));
      await tester.pumpAndSettle();
      expect(find.text('Mail Geçmişi (4)'), findsOneWidget);
      expect(find.text('eski@modayapi.com.tr'), findsOneWidget);
      expect(find.text('Teklif oluşturuldu'), findsNothing);
    });

    testWidgets('boş geçmiş', (tester) async {
      await pump(tester, repo: FakeOfferHistoryRepository(eventItems: const [], emailItems: const []));
      expect(find.text('Henüz kayıtlı bir olay yok.'), findsOneWidget);
    });

    testWidgets('403: bölüm çökmez, not gösterir; tam ekran "Yetkin yok"', (tester) async {
      final repo = FakeOfferHistoryRepository()..error = forbidden;
      await pump(tester, repo: repo);
      expect(find.text(kOfferHistoryNoAccessText), findsOneWidget);
      expect(tester.takeException(), isNull);
      await pump(tester, repo: repo, location: offerHistoryPath(kOfferId));
      expect(find.text('Yetkin yok'), findsOneWidget);
    });

    testWidgets('invalidateOfferHistory yeniden çeker', (tester) async {
      final repo = await pump(tester);
      expect(repo.calls, ['history:o1']);
      await tester.tap(find.byTooltip('Yenile'));
      await tester.pumpAndSettle();
      expect(repo.calls, ['history:o1', 'history:o1']);
    });
  });
}
