import 'package:go_router/go_router.dart';

import 'presentation/offer_history_screen.dart';

export 'data/offer_history_providers.dart' show offerHistoryProvider, invalidateOfferHistory;
export 'offer_history_paths.dart';
export 'presentation/offer_history_section.dart' show OfferHistorySection;

/// Teklif detayının (`/teklifler/:id`) `routes:` listesine eklenecek ALT
/// rota -- yol GÖRELİDİR: `gecmis` -> `/teklifler/:id/gecmis`
/// (`?sekme=eposta` ile "Mail Geçmişi" sekmesi açılır).
///
/// Kayıt: app_router.dart'ta `/teklifler` altındaki `:id` GoRoute'una
/// `routes: offerHistoryRoutes`. Bölüm: `OfferDetailScreen` listesinde
/// "Revizyon Geçmişi"nin altına `OfferHistorySection(offerId: offerId)`;
/// detayın `onRefresh`'i ve olay üreten aksiyonları (_setStatus,
/// _sendEmail, _createShareLink, _reviseAndEdit, _convert) sonrasında
/// `invalidateOfferHistory(ref.invalidate, offerId)` (await sonrası: kapsayıcının `invalidate`'i).
final List<RouteBase> offerHistoryRoutes = [
  GoRoute(
    path: 'gecmis',
    builder: (context, state) => OfferHistoryScreen(
      offerId: state.pathParameters['id']!,
      initialTab: state.uri.queryParameters['sekme'] == 'eposta' ? OfferHistoryTab.emails : OfferHistoryTab.events,
    ),
  ),
];
