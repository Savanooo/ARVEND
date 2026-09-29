import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:arvend/core/theme/app_spacing.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/core/theme/app_typography.dart';
import 'package:arvend/features/offers/history/data/offer_history_providers.dart';
import 'package:arvend/features/offers/history/data/offer_history_repository.dart';
import 'package:arvend/features/offers/history/domain/offer_history.dart';
import 'package:arvend/features/offers/history/offer_history_routes.dart';

export '../suppliers/suppliers_test_support.dart' show goldenTheme, loadAppFonts, forbidden;

/// Teklif geçmişi testlerinin ortak kurulumu: sahte depo (ağ YOK) ve
/// teklif detayını taklit eden ev sahibi (bölüm `ListView` içinde, tam
/// ekran `offerHistoryRoutes` ile `/teklifler/:id` altında).

const kOfferId = 'o1';

const kRevisionNos = {'r1': 1, 'r2': 2};

/// Backend sırası: created_at ASC. Saatler UTC; ekranda İstanbul (+3).
const kOfferEventFixtures = <OfferEvent>[
  OfferEvent(id: 'ev1', eventType: 'offer_created', createdAt: '2026-09-10T07:30:00Z'),
  OfferEvent(id: 'ev2', revisionId: 'r1', eventType: 'share_link_created', createdAt: '2026-09-10T08:00:00Z'),
  OfferEvent(id: 'ev3', revisionId: 'r1', eventType: 'revision_sent', createdAt: '2026-09-10T08:05:00Z'),
  OfferEvent(id: 'ev4', revisionId: 'r1', eventType: 'email_sent', createdAt: '2026-09-10T08:05:30Z'),
  OfferEvent(id: 'ev5', revisionId: 'r1', eventType: 'customer_viewed', createdAt: '2026-09-11T06:12:00Z'),
  OfferEvent(id: 'ev6', revisionId: 'r1', eventType: 'customer_viewed', createdAt: '2026-09-12T15:40:00Z'),
  OfferEvent(id: 'ev7', revisionId: 'r2', eventType: 'revision_created', createdAt: '2026-09-15T09:00:00Z'),
  OfferEvent(id: 'ev8', revisionId: 'r2', eventType: 'offer_updated', createdAt: '2026-09-15T09:20:00Z'),
  OfferEvent(
    id: 'ev9',
    revisionId: 'r1',
    eventType: 'share_link_revoked',
    metadata: {'reason': 'revision_sent'},
    createdAt: '2026-09-16T07:00:00Z',
  ),
  OfferEvent(id: 'ev10', revisionId: 'r2', eventType: 'revision_sent', createdAt: '2026-09-16T07:00:10Z'),
  OfferEvent(id: 'ev11', revisionId: 'r2', eventType: 'email_failed', createdAt: '2026-09-16T07:01:00Z'),
  OfferEvent(id: 'ev12', revisionId: 'r2', eventType: 'email_sent', createdAt: '2026-09-16T07:10:00Z'),
  OfferEvent(id: 'ev13', revisionId: 'r2', eventType: 'customer_viewed', createdAt: '2026-09-17T11:00:00Z'),
  OfferEvent(id: 'ev14', revisionId: 'r2', eventType: 'customer_accepted', createdAt: '2026-09-18T12:30:00Z'),
  OfferEvent(
    id: 'ev15',
    eventType: 'project_created',
    metadata: {'project_no': 'PRJ-2026-0007'},
    createdAt: '2026-09-19T08:00:00Z',
  ),
];

/// Backend sırası: sent_at DESC.
const kOfferEmailFixtures = <OfferEmailLog>[
  OfferEmailLog(
    id: 'ml3',
    revisionId: 'r2',
    recipient: 'satinalma@modayapi.com.tr',
    subject: 'Teklif TKL-2026-0031',
    status: OfferEmailLog.statusSent,
    sentAt: '2026-09-16T07:10:00Z',
  ),
  OfferEmailLog(
    id: 'ml2',
    revisionId: 'r2',
    recipient: 'satinalma@modayapi.com.tr',
    subject: 'Teklif TKL-2026-0031',
    status: OfferEmailLog.statusFailed,
    errorMessage: 'SMTP sunucusuna bağlanılamadı (zaman aşımı)',
    sentAt: '2026-09-16T07:01:00Z',
  ),
  OfferEmailLog(
    id: 'ml1',
    revisionId: 'r1',
    recipient: 'info@modayapi.com.tr',
    subject: 'Teklif TKL-2026-0031',
    status: OfferEmailLog.statusSent,
    sentAt: '2026-09-10T08:05:30Z',
  ),
];

class FakeOfferHistoryRepository implements OfferHistoryRepository {
  FakeOfferHistoryRepository({
    this.eventItems = kOfferEventFixtures,
    this.emailItems = kOfferEmailFixtures,
    this.revisionNos = kRevisionNos,
  });

  List<OfferEvent> eventItems;
  List<OfferEmailLog> emailItems;
  Map<String, int> revisionNos;
  Object? error;
  final List<String> calls = [];

  @override
  Future<List<OfferEvent>> events(String offerId) async => eventItems;

  @override
  Future<List<OfferEmailLog>> emailLogs(String offerId) async => emailItems;

  @override
  Future<Map<String, int>> revisionNumbers(String offerId) async => revisionNos;

  @override
  Future<OfferHistory> history(String offerId) async {
    calls.add('history:$offerId');
    if (error != null) throw error!;
    return OfferHistory(events: eventItems, emailLogs: emailItems, revisionNoById: revisionNos);
  }
}

/// Teklif detayı yerine: bölüm, gerçek ekrandaki gibi bir `ListView`'ın
/// içinde ("Revizyon Geçmişi"nin altında). AppBar'daki yenile düğmesi
/// detayın pull-to-refresh kancasını (`invalidateOfferHistory`) dener.
class OfferDetailHost extends ConsumerWidget {
  const OfferDetailHost({super.key, required this.offerId});

  final String offerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TKL-2026-0031'),
        actions: [
          IconButton(
            tooltip: 'Yenile',
            icon: const Icon(Icons.refresh),
            onPressed: () => invalidateOfferHistory(ref.invalidate, offerId),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          const Text('Revizyon Geçmişi', style: AppTypography.sectionTitle),
          const SizedBox(height: AppSpacing.xl),
          OfferHistorySection(offerId: offerId),
        ],
      ),
    );
  }
}

Widget buildOfferHistoryApp({
  required FakeOfferHistoryRepository repo,
  String initialLocation = '/teklifler/$kOfferId',
  ThemeData? theme,
}) {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/teklifler',
        builder: (_, _) => const Scaffold(body: Center(child: Text('Teklifler'))),
        routes: [
          GoRoute(
            path: ':id',
            builder: (_, state) => OfferDetailHost(offerId: state.pathParameters['id']!),
            routes: offerHistoryRoutes,
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: [offerHistoryRepositoryProvider.overrideWithValue(repo)],
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: theme ?? AppTheme.light(),
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      routerConfig: router,
    ),
  );
}
