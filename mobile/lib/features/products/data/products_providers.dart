import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/price_change.dart';
import '../domain/price_format.dart';
import '../domain/price_source.dart';
import '../domain/product.dart';
import 'products_repository.dart';

final productsRepositoryProvider = Provider<ProductsRepository>(
  (ref) => ProductsRepository(ref.watch(apiClientProvider)),
);

/// Saat kaynağı -- Zam Geçmişi dönemleri İstanbul'un "bugün"üne göre
/// hesaplanır; testler/golden'lar sabit bir an verir.
final productsClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// İstanbul'un bugünü (YYYY-AA-GG).
final productsTodayProvider = Provider<String>((ref) => istanbulDay(ref.watch(productsClockProvider)()));

/// Sayfa sayfa büyüyen liste durumu (katalog ve zam listesi). `total`
/// backend'in toplamıdır; boş bir sayfa gelirse (liste bu arada kısaldı)
/// `reachedEnd` ile durulur.
class PagedList<T> {
  const PagedList({
    required this.items,
    required this.total,
    required this.page,
    this.reachedEnd = false,
    this.loadingMore = false,
    this.loadMoreError,
  });

  final List<T> items;
  final int total;
  final int page;
  final bool reachedEnd;
  final bool loadingMore;
  final Object? loadMoreError;

  bool get hasMore => !reachedEnd && items.length < total;

  PagedList<T> copyWith({bool? loadingMore, Object? loadMoreError, bool clearError = false}) => PagedList(
    items: items,
    total: total,
    page: page,
    reachedEnd: reachedEnd,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreError: clearError ? null : (loadMoreError ?? this.loadMoreError),
  );
}

/// Ortak "daha fazla yükle" mantığı. Sayfalar arasında katalog değişirse
/// (OFFSET kayması) aynı kayıt iki kez gelmesin diye kimliğe göre tekilleşir.
abstract class _PagedNotifier<T, A> extends AutoDisposeFamilyAsyncNotifier<PagedList<T>, A> {
  // Yenileme (invalidate) build'i yeniden çalıştırır: o sırada uçan bir
  // "daha fazla" isteği eski listeyi geri yazmasın diye nesil sayılır.
  int _generation = 0;
  bool _alive = true;

  Future<({List<T> items, int total})> fetchPage(A arg, int page);
  String idOf(T item);

  @override
  Future<PagedList<T>> build(A arg) async {
    _generation++;
    _alive = true;
    ref.onDispose(() => _alive = false);
    final first = await fetchPage(arg, 1);
    return PagedList(items: first.items, total: first.total, page: 1, reachedEnd: first.items.isEmpty);
  }

  /// [auto]: kaydırma dinleyicisinden gelen çağrı. Son istek hata
  /// verdiyse otomatik çağrı YENİDEN DENEMEZ -- aksi halde çevrimdışıyken
  /// her kaydırma bildirimi yeni bir istek atıp hatayı silerdi; yeniden
  /// deneme yalnızca "Tekrar Dene" düğmesiyle (auto: false).
  Future<void> loadMore({bool auto = false}) async {
    final current = state.valueOrNull;
    if (current == null || current.loadingMore || !current.hasMore || state.isLoading) return;
    if (auto && current.loadMoreError != null) return;
    final generation = _generation;
    bool stale() => !_alive || generation != _generation;
    state = AsyncData(current.copyWith(loadingMore: true, clearError: true));
    try {
      final next = await fetchPage(arg, current.page + 1);
      if (stale()) return;
      final seen = {for (final i in current.items) idOf(i)};
      final fresh = [for (final i in next.items) if (seen.add(idOf(i))) i];
      state = AsyncData(PagedList(
        items: [...current.items, ...fresh],
        total: next.total,
        page: current.page + 1,
        reachedEnd: next.items.isEmpty,
      ));
    } catch (e) {
      if (stale()) return;
      state = AsyncData(current.copyWith(loadingMore: false, loadMoreError: e));
    }
  }
}

/// Katalog listesi; aile anahtarı arama metnidir.
class ProductListNotifier extends _PagedNotifier<Product, String> {
  @override
  Future<({List<Product> items, int total})> fetchPage(String q, int page) async {
    final res = await ref.read(productsRepositoryProvider).list(q: q, page: page);
    return (items: res.products, total: res.total);
  }

  @override
  String idOf(Product item) => item.id;
}

final productListProvider =
    AsyncNotifierProvider.autoDispose.family<ProductListNotifier, PagedList<Product>, String>(ProductListNotifier.new);

final productDetailProvider = FutureProvider.autoDispose.family<Product, String>(
  (ref, id) => ref.watch(productsRepositoryProvider).get(id),
);

final productPriceHistoryProvider = FutureProvider.autoDispose.family<List<PriceHistoryEntry>, String>(
  (ref, id) => ref.watch(productsRepositoryProvider).priceHistory(id),
);

final priceSourcesProvider = FutureProvider.autoDispose<List<PriceSource>>(
  (ref) => ref.watch(productsRepositoryProvider).priceSources(),
);

final priceChangeSummaryProvider = FutureProvider.autoDispose.family<PriceChangeSummary, PriceChangeSummaryQuery>(
  (ref, q) => ref.watch(productsRepositoryProvider).priceChangeSummary(q),
);

/// Zam listesi; aile anahtarı sayfa hariç tüm sorgu.
class PriceChangesNotifier extends _PagedNotifier<PriceChange, PriceChangesQuery> {
  @override
  Future<({List<PriceChange> items, int total})> fetchPage(PriceChangesQuery q, int page) async {
    final res = await ref.read(productsRepositoryProvider).priceChanges(q, page: page);
    return (items: res.changes, total: res.total);
  }

  @override
  String idOf(PriceChange item) => item.id;
}

final priceChangesListProvider = AsyncNotifierProvider.autoDispose
    .family<PriceChangesNotifier, PagedList<PriceChange>, PriceChangesQuery>(PriceChangesNotifier.new);

/// Bir yazma işleminden (ürün ekle/düzenle, senkron, kâr oranı) sonra
/// ürünle ilgili TÜM önbellekleri tazeler -- fiyatlar birbirine bağlıdır
/// (kâr oranı -> satış fiyatı -> zam geçmişi).
void invalidateProductData(void Function(ProviderOrFamily provider) invalidate) {
  invalidate(productListProvider);
  invalidate(productDetailProvider);
  invalidate(productPriceHistoryProvider);
  invalidate(priceSourcesProvider);
  invalidate(priceChangeSummaryProvider);
  invalidate(priceChangesListProvider);
}
