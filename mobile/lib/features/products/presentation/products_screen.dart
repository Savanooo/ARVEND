import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/products_providers.dart';
import '../domain/price_format.dart';
import '../domain/price_source.dart';
import '../domain/product.dart';
import 'products_paths.dart';
import 'widgets/products_common.dart';

/// Ürünler kataloğu (web /admin/urunler): aranabilir, sayfa sayfa yüklenen
/// liste + fiyat kaynağı özeti. products.read ile açılır; ekleme ve
/// tedarikçi fiyatı yalnızca products.manage ile.
class ProductsScreen extends ConsumerWidget {
  const ProductsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canRead = productsCan(ref, ProductsPermissions.read);
    final canManage = productsCan(ref, ProductsPermissions.manage);
    return AppPageScaffold(
      title: const Text('Ürünler'),
      actions: [
        // Zam geçmişi uçları da yalnızca products.read ister.
        if (canRead)
          IconButton(
            tooltip: 'Zam Geçmişi',
            icon: const Icon(Icons.trending_up),
            onPressed: () => context.push(ProductsPaths.priceChanges),
          ),
      ],
      floatingActionButton: canManage
          ? FloatingActionButton(
              tooltip: 'Yeni Ürün',
              onPressed: () => context.push(ProductsPaths.create),
              child: const Icon(Icons.add),
            )
          : null,
      body: const ProductsAccessGate(permission: ProductsPermissions.read, child: _ProductsBody()),
    );
  }
}

class _ProductsBody extends ConsumerStatefulWidget {
  const _ProductsBody();

  @override
  ConsumerState<_ProductsBody> createState() => _ProductsBodyState();
}

class _ProductsBodyState extends ConsumerState<_ProductsBody> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _applySearch(value));
  }

  void _applySearch(String value) {
    _debounce?.cancel();
    final q = value.trim();
    if (q != _query && mounted) setState(() => _query = q);
  }

  Future<void> _refresh() async {
    ref.invalidate(priceSourcesProvider);
    ref.invalidate(productListProvider(_query));
    try {
      await ref.read(productListProvider(_query).future);
    } catch (_) {
      // Hata ekranda gösterilir.
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 400) {
      // Otomatik: son "daha fazla" isteği hata verdiyse kaydırma yeniden
      // denemez (yalnızca "Tekrar Dene" düğmesi).
      ref.read(productListProvider(_query).notifier).loadMore(auto: true);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final listAsync = ref.watch(productListProvider(_query));
    // Fiyat kaynağı ucu da yalnızca products.read ister; hatası listeyi
    // düşürmez -- "listede yok" rozetleri o durumda gösterilmez.
    final sourcesAsync = ref.watch(priceSourcesProvider);
    final sources = sourcesAsync.valueOrNull;
    final canManage = productsCan(ref, ProductsPermissions.manage);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _searchController,
            builder: (context, value, _) => TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Ürün, kategori, tedarikçi ara…',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                suffixIcon: value.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Aramayı temizle',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _searchController.clear();
                          _applySearch('');
                        },
                      ),
              ),
              onChanged: _onSearchChanged,
              onSubmitted: _applySearch,
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: ProductsAsyncView(
              value: listAsync,
              onRetry: _refresh,
              data: (context, page) => NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 88),
                  children: [
                    if (!canManage) ...[
                      const ReadOnlyNotice(kProductsListReadOnly),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    _SourcesSummaryCard(value: sourcesAsync, listedSources: page.items.map((p) => p.source)),
                    const SizedBox(height: AppSpacing.md),
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: Text(
                        _query.isEmpty ? 'Toplam ${page.total} ürün' : '“$_query” için ${page.total} ürün',
                        style: AppTypography.metadata,
                      ),
                    ),
                    if (page.items.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xl),
                        child: EmptyStateView(
                          message: page.total > 0 ? 'Bu sayfada ürün yok.' : 'Ürün bulunamadı.',
                          icon: Icons.inventory_2_outlined,
                        ),
                      ),
                    for (final p in page.items)
                      _ProductRow(
                        product: p,
                        priceSource: findPriceSource(sources, p.source),
                        showSourcePrice: canManage,
                        onTap: () => context.push(ProductsPaths.detail(p.id)),
                      ),
                    _LoadMoreFooter(
                      page: page,
                      onLoadMore: () => ref.read(productListProvider(_query).notifier).loadMore(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Liste sonu: yükleniyor / hata + tekrar dene / "daha fazla" düğmesi.
class _LoadMoreFooter extends StatelessWidget {
  const _LoadMoreFooter({required this.page, required this.onLoadMore});
  final PagedList<Product> page;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (page.loadingMore) {
      return const Padding(padding: EdgeInsets.all(AppSpacing.lg), child: LoadingState());
    }
    if (page.loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Column(
          children: [
            Text(productsLoadError(page.loadMoreError!), style: AppTypography.error, textAlign: TextAlign.center),
            TextButton(onPressed: onLoadMore, child: const Text('Tekrar Dene')),
          ],
        ),
      );
    }
    if (page.hasMore) {
      return Center(
        child: TextButton(
          onPressed: onLoadMore,
          child: Text('Daha fazla göster (${page.items.length} / ${page.total})'),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({
    required this.product,
    required this.priceSource,
    required this.showSourcePrice,
    required this.onTap,
  });

  final Product product;
  final PriceSource? priceSource;
  final bool showSourcePrice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = product;
    final missing = isMissingFromSource(p, priceSource);
    final meta = [p.unit, if (p.category.isNotEmpty) p.category].where((s) => s.isNotEmpty).join(' · ');
    // Tedarikçi fiyatı (kâr oranı uygulanmamış) yalnızca products.manage
    // sahibine gelir; ekran ayrıca izne de bakar.
    final sourcePrice = showSourcePrice ? p.sourcePrice : null;
    return AppCard(
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name, style: AppTypography.cardTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(meta, style: AppTypography.metadata, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
                if (!p.isManual) ...[
                  const SizedBox(height: AppSpacing.xs + 2),
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      SourceBadge(source: p.source, name: priceSource?.name),
                      if (missing) MissingFromSourceBadge(source: p.source, name: priceSource?.name),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              MoneyText(p.unitPrice, style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
              if (p.unit.isNotEmpty) Text('/ ${p.unit}', style: AppTypography.helper),
              if (sourcePrice != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text('Tedarikçi', style: AppTypography.helper),
                MoneyText(sourcePrice, style: AppTypography.helper),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Listenin üstündeki kısa fiyat kaynağı özeti; dokununca Fiyat Kaynakları.
/// Web'deki kaynak kartları gibi zorunlu kaynak gösterimini de taşır
/// (Demir Profil: "Kaynak: demirprofil.com.tr — Eylül 2026 listesi" gibi) -- katalog
/// Demir Profil fiyatları gösterir.
class _SourcesSummaryCard extends StatelessWidget {
  const _SourcesSummaryCard({required this.value, required this.listedSources});
  final AsyncValue<List<PriceSource>> value;

  /// Bu sayfada fiyatı gösterilen ürünlerin kaynak kodları: kaynak bilgisi
  /// alınamazsa Demir Profil fiyatları yine kaynaksız kalmasın.
  final Iterable<String> listedSources;

  @override
  Widget build(BuildContext context) {
    final sources = value.valueOrNull;
    final fallbackAttributions = sources == null ? attributionsFor(listedSources, null) : const <String>[];
    return AppCard(
      onTap: () => context.push(ProductsPaths.sources),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
      child: Row(
        children: [
          const Icon(Icons.cloud_sync_outlined, color: AppColors.gold, size: 22),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Fiyat Kaynakları', style: AppTypography.cardTitle),
                const SizedBox(height: 2),
                if (sources == null) ...[
                  Text(
                    value.hasError ? 'Fiyat kaynağı bilgisi şu anda alınamadı.' : 'Yükleniyor…',
                    style: AppTypography.metadata,
                  ),
                  for (final text in fallbackAttributions)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(text, style: AppTypography.helper),
                    ),
                ] else
                  for (final ps in sources) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      // Dar ekranda "Başarısız" rozeti alt satıra iner, tarih kesilmez.
                      child: Wrap(
                        spacing: AppSpacing.xs,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            '${sourceLabels(ps.source, ps.name).short} · '
                            '${ps.lastSyncedAt == null ? 'Hiç çekilmedi' : formatChangeTime(ps.lastSyncedAt!)}',
                            style: AppTypography.metadata,
                          ),
                          if (ps.lastStatus == PriceSyncStatus.failed)
                            const StatusBadge(label: 'Başarısız', tone: StatusTone.danger),
                        ],
                      ),
                    ),
                    if (ps.attribution.isNotEmpty) Text(ps.attribution, style: AppTypography.helper),
                  ],
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
  }
}
