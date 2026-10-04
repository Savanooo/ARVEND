import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/offer.dart';
import 'offers_repository.dart';

final offersRepositoryProvider =
    Provider<OffersRepository>((ref) => OffersRepository(ref.watch(apiClientProvider)));

final offersListProvider = FutureProvider.autoDispose.family<({List<Offer> offers, int total}), String>(
  (ref, filter) => ref.watch(offersRepositoryProvider).list(filter: filter),
);

final offerDetailProvider = FutureProvider.autoDispose.family<Offer, String>(
  (ref, id) => ref.watch(offersRepositoryProvider).get(id),
);

/// Müşteri detay ekranının "Teklifler" bölümü için -- backend'in yeni
/// eklenen (bkz. bu modülün backend değişikliği) `GET /offers?customer_id=`
/// filtresini kullanır. `offer_revisions.customer_id` yalnızca teklif bir
/// müşteri kartından oluşturulduysa dolu olur (serbest metinle girilmiş
/// eski/manuel teklifler bu listede görünmez -- bkz. backend doğrulaması).
final customerOffersProvider = FutureProvider.autoDispose.family<({List<Offer> offers, int total}), String>(
  (ref, customerId) => ref.watch(offersRepositoryProvider).list(customerId: customerId, limit: 200),
);

final offerRevisionsProvider = FutureProvider.autoDispose.family<List<OfferRevision>, String>(
  (ref, id) => ref.watch(offersRepositoryProvider).revisions(id),
);

typedef OfferRevisionKey = ({String offerId, String revisionId});

final offerRevisionDetailProvider = FutureProvider.autoDispose.family<OfferRevision, OfferRevisionKey>(
  (ref, key) => ref.watch(offersRepositoryProvider).getRevision(key.offerId, key.revisionId),
);

/// Teklif zaten bir projeye dönüştürülmüşse o projenin id'sini döner, aksi
/// halde null -- "Projeye Dönüştür" ile "Projeyi Görüntüle" arasında karar
/// vermek ve tekrar dönüştürmeyi (yinelenen proje) önlemek için kullanılır.
final offerLinkedProjectIdProvider = FutureProvider.autoDispose.family<String?, String>(
  (ref, id) => ref.watch(offersRepositoryProvider).linkedProjectId(id),
);

/// Teklifin paylaşım linkleri (aktif + iptal edilmiş/süresi dolmuş).
final offerShareLinksProvider = FutureProvider.autoDispose.family<List<ShareLink>, String>(
  (ref, id) => ref.watch(offersRepositoryProvider).shareLinks(id),
);
