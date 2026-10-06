import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/offer.dart';
import 'offers_repository.dart';

final offersRepositoryProvider =
    Provider<OffersRepository>((ref) => OffersRepository(ref.watch(apiClientProvider)));

/// Teklif listesinin TAZELEME SİNYALİ (anahtar: '' = aktif, 'pasif').
/// Teklif detay/oluşturma ekranları bir değişiklikten sonra
/// `ref.invalidate(offersListProvider(''))` çağırır; Teklifler ekranının
/// sayfalı listesi ([offersPagedProvider]) bunu izler ve baştan yüklenir.
/// Her yeniden kuruluşta YENİ bir nesne döner -- aynı değer dönseydi
/// Riverpod izleyenleri uyandırmazdı.
final offersListProvider = Provider.autoDispose.family<Object, String>((ref, filter) => Object());

/// Teklifler ekranının sorgusu: aktif/pasif, durum sekmesi ('' = tümü) ve
/// arama metni -- üçü de SUNUCUDA uygulanır.
typedef OfferListQuery = ({bool passive, String status, String q});

/// Sayfa sayfa büyüyen teklif listesi. `total` filtrenin gerçek toplamı,
/// `statusCounts` sekme sayaçlarıdır (ikisi de backend'den; yalnızca
/// yüklenen satırları saymaz).
class OffersPagedState {
  const OffersPagedState({
    required this.offers,
    required this.total,
    required this.statusCounts,
    required this.page,
    this.reachedEnd = false,
    this.loadingMore = false,
    this.loadMoreError,
  });

  final List<Offer> offers;
  final int total;
  final Map<String, int> statusCounts;
  final int page;
  final bool reachedEnd;
  final bool loadingMore;
  final Object? loadMoreError;

  bool get hasMore => !reachedEnd && offers.length < total;

  /// "Tümü" sekmesinin sayacı.
  int get allCount => statusCounts.values.fold(0, (a, b) => a + b);

  OffersPagedState copyWith({bool? loadingMore, Object? loadMoreError, bool clearError = false}) => OffersPagedState(
    offers: offers,
    total: total,
    statusCounts: statusCounts,
    page: page,
    reachedEnd: reachedEnd,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreError: clearError ? null : (loadMoreError ?? this.loadMoreError),
  );
}

/// Ürün kataloğundaki sayfalı listeyle (products_providers.dart) aynı
/// "daha fazla yükle" mantığı: yenileme sırasında uçan eski istek listeyi
/// geri yazmasın diye nesil sayılır; sayfalar arası kayma olursa aynı
/// teklif iki kez gösterilmez.
class OffersPagedNotifier extends AutoDisposeFamilyAsyncNotifier<OffersPagedState, OfferListQuery> {
  int _generation = 0;
  bool _alive = true;

  Future<OfferListPage> _fetch(OfferListQuery query, int page) =>
      ref.read(offersRepositoryProvider).page(passive: query.passive, status: query.status, q: query.q, page: page);

  @override
  Future<OffersPagedState> build(OfferListQuery query) async {
    ref.watch(offersListProvider(query.passive ? 'pasif' : ''));
    _generation++;
    _alive = true;
    ref.onDispose(() => _alive = false);
    final first = await _fetch(query, 1);
    return OffersPagedState(
      offers: first.offers,
      total: first.total,
      statusCounts: first.statusCounts,
      page: 1,
      reachedEnd: first.offers.isEmpty,
    );
  }

  /// [auto]: kaydırmadan gelen çağrı -- son istek hata verdiyse otomatik
  /// yeniden denemez (yalnızca "Tekrar Dene").
  Future<void> loadMore({bool auto = false}) async {
    final current = state.valueOrNull;
    if (current == null || current.loadingMore || !current.hasMore || state.isLoading) return;
    if (auto && current.loadMoreError != null) return;
    final generation = _generation;
    bool stale() => !_alive || generation != _generation;
    state = AsyncData(current.copyWith(loadingMore: true, clearError: true));
    try {
      final next = await _fetch(arg, current.page + 1);
      if (stale()) return;
      final seen = {for (final o in current.offers) o.id};
      final fresh = [for (final o in next.offers) if (seen.add(o.id)) o];
      state = AsyncData(OffersPagedState(
        offers: [...current.offers, ...fresh],
        total: next.total,
        statusCounts: next.statusCounts,
        page: current.page + 1,
        reachedEnd: next.offers.isEmpty,
      ));
    } catch (e) {
      if (stale()) return;
      state = AsyncData(current.copyWith(loadingMore: false, loadMoreError: e));
    }
  }
}

final offersPagedProvider =
    AsyncNotifierProvider.autoDispose.family<OffersPagedNotifier, OffersPagedState, OfferListQuery>(
      OffersPagedNotifier.new,
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
