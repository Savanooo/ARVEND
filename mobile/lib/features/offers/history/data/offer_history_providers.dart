import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_providers.dart';
import '../domain/offer_history.dart';
import 'offer_history_repository.dart';

final offerHistoryRepositoryProvider =
    Provider<OfferHistoryRepository>((ref) => OfferHistoryRepository(ref.watch(apiClientProvider)));

/// Teklif geçmişi (olaylar + e-posta kayıtları + revizyon numaraları).
/// Teklif detayındaki bir işlem (durum değişikliği, e-posta, paylaşım
/// linki, projeye dönüştürme) yeni olay ürettiğinde çağıran taraf
/// [invalidateOfferHistory] ile tazeler.
final offerHistoryProvider = FutureProvider.autoDispose.family<OfferHistory, String>(
  (ref, offerId) => ref.watch(offerHistoryRepositoryProvider).history(offerId),
);

/// Teklif detayının pull-to-refresh'i ve olay üreten aksiyonları sonrası
/// çağrılır. [invalidate]: eşzamanlı yerde `ref.invalidate`; bir await'ten
/// SONRA ise ilk await'ten önce alınmış kapsayıcının `invalidate`'i (ekran
/// bu arada kapandıysa `WidgetRef` StateError atar, tazeleme kaybolurdu).
void invalidateOfferHistory(void Function(ProviderOrFamily provider) invalidate, String offerId) =>
    invalidate(offerHistoryProvider(offerId));
