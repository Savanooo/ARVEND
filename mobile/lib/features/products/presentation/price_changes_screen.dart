import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_filter_bar.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/skeleton_box.dart';
import '../data/products_providers.dart';
import '../domain/price_change.dart';
import '../domain/price_format.dart';
import '../domain/price_source.dart';
import 'price_changes_filter_sheet.dart';
import 'products_paths.dart';
import 'widgets/products_common.dart';

/// Zam Geçmişi (web /admin/urunler/zamlar): tedarikçi listelerinden, kâr
/// oranı değişikliklerinden ve elle düzenlemelerden gelen fiyat
/// değişiklikleri. Yalnızca okuma: products.read yeter. Tedarikçi (maliyet)
/// fiyatlarını backend yalnızca products.manage sahibine döndürür; satırda
/// da yalnızca döndüyse görünür.
class PriceChangesScreen extends StatelessWidget {
  const PriceChangesScreen({super.key, this.initialParams = const ZamlarParams()});

  /// Rota sorgusundan (bkz. ZamlarParams.fromQuery) -- ör. fiyat kaynağı
  /// kartının "Zam Geçmişi" bağlantısı olay kapsamıyla açar.
  final ZamlarParams initialParams;

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(
      title: const Text('Zam Geçmişi'),
      body: ProductsAccessGate(
        permission: ProductsPermissions.read,
        child: _PriceChangesBody(initialParams: initialParams),
      ),
    );
  }
}

class _PriceChangesBody extends ConsumerStatefulWidget {
  const _PriceChangesBody({required this.initialParams});
  final ZamlarParams initialParams;

  @override
  ConsumerState<_PriceChangesBody> createState() => _PriceChangesBodyState();
}

/// Zaman çizelgesinde başta gösterilen olay sayısı.
const _kCollapsedEvents = 5;

class _PriceChangesBodyState extends ConsumerState<_PriceChangesBody> {
  late ZamlarParams _params = widget.initialParams;
  bool _showAllEvents = false;
  final _listHeaderKey = GlobalKey();

  void _setParams(ZamlarParams next, {bool scrollToList = false}) {
    setState(() => _params = next);
    if (scrollToList) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _listHeaderKey.currentContext;
        if (ctx != null && ctx.mounted) {
          Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 250), alignment: 0.05);
        }
      });
    }
  }

  Future<void> _pickPeriod(String period, ResolvedPeriod range, String today) async {
    if (period != PeriodKey.custom) {
      _setParams(changePeriod(_params, period));
      return;
    }
    final last = parseDay(today)!;
    final start = parseDay(range.from) ?? last;
    final end = parseDay(range.to) ?? last;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime.utc(2000),
      lastDate: last,
      initialDateRange: DateTimeRange(start: start.isAfter(last) ? last : start, end: end.isAfter(last) ? last : end),
      helpText: 'Özel aralık',
      saveText: 'Uygula',
    );
    if (picked == null || !mounted) return;
    _setParams(changePeriod(_params, PeriodKey.custom, from: dayOf(picked.start), to: dayOf(picked.end)));
  }

  Future<void> _openFilters(List<PriceSource>? sources, List<String> categories) async {
    final options = [
      for (final code in sources?.map((s) => s.source) ?? kKnownPriceSources)
        (code: code, name: sourceLabels(code, findPriceSource(sources, code)?.name).short),
    ];
    final next = await showPriceChangesFilterSheet(context, params: _params, sources: options, categories: categories);
    if (next != null && mounted) _setParams(next);
  }

  Future<void> _refresh(PriceChangeSummaryQuery summaryQ, PriceChangesQuery listQ) async {
    ref.invalidate(priceChangeSummaryProvider(summaryQ));
    ref.invalidate(priceChangesListProvider(listQ));
    ref.invalidate(priceSourcesProvider);
    try {
      await ref.read(priceChangesListProvider(listQ).future);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(productsTodayProvider);
    final range = resolvePeriod(_params, today);
    final summaryQ = summaryQueryOf(_params, range);
    final listQ = listQueryOf(_params, range);
    final summaryAsync = ref.watch(priceChangeSummaryProvider(summaryQ));
    final listAsync = ref.watch(priceChangesListProvider(listQ));
    // Yalnızca kaynak adları, kategori önerileri ve kaynak gösterimi için;
    // hatası ekranı düşürmez.
    final sources = ref.watch(priceSourcesProvider).valueOrNull;
    final canManage = productsCan(ref, ProductsPermissions.manage);
    final summary = summaryAsync.valueOrNull;
    final list = listAsync.valueOrNull;

    String sourceName(String code) => sourceLabels(code, findPriceSource(sources, code)?.name).short;

    final categories = {
      for (final s in sources ?? const <PriceSource>[])
        for (final c in s.categories) c.category,
      for (final c in list?.items ?? const <PriceChange>[]) c.category,
    }.where((c) => c.isNotEmpty).toList()
      ..sort(compareTr);

    // Dönem kendi satırında (tarihler bölünmeden), kaynak/neden altında.
    final rangeText = '${range.label}: ${formatDayRangeNoBreak(range.from, range.to)}';
    final filterText = [
      _params.source.isNotEmpty ? sourceName(_params.source) : 'Tüm kaynaklar',
      reasonFilterLabel(_params.reason),
    ].join(' · ');

    // Demir Profil'in kullanım koşulu: fiyatlarının gösterildiği her yerde
    // kaynak ve liste ayı belirtilir.
    final attributions = attributionsFor([
      _params.source,
      _params.event?.source,
      ...?list?.items.map((c) => c.source),
      ...?summary?.events.map((e) => e.source),
    ], sources);

    return RefreshIndicator(
      onRefresh: () => _refresh(summaryQ, listQ),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 400) {
            ref.read(priceChangesListProvider(listQ).notifier).loadMore(auto: true);
          }
          return false;
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xxl),
          children: [
            // Beş dönem seçeneği sarılır: yatay kaydırmada sonuncular ekran
            // kenarında yarım kalıyordu.
            AppFilterBar(
              wrap: true,
              chips: [
                for (final (key, label) in kPeriodOptions)
                  AppFilterChipData(
                    label: label,
                    selected: _params.period == key,
                    onTap: () => _pickPeriod(key, range, today),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rangeText,
                        style: AppTypography.metadata.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(filterText, style: AppTypography.metadata),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                TextButton.icon(
                  onPressed: () => _openFilters(sources, categories),
                  icon: const Icon(Icons.tune, size: 18),
                  label: Text(
                    _params.activeFilterCount == 0 ? 'Filtrele' : 'Filtrele (${_params.activeFilterCount})',
                  ),
                ),
              ],
            ),
            if (range.error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              ProductsNotice(tone: NoticeTone.danger, text: range.error!),
            ],
            const SizedBox(height: AppSpacing.md),
            // Özet: dönem + kaynak + neden (yön/kategori/arama listeye özgü).
            summaryAsync.when(
              skipLoadingOnRefresh: true,
              loading: () => const _SummarySkeleton(),
              error: (e, _) => ProductsNotice(tone: NoticeTone.danger, text: 'Özet alınamadı: ${productsLoadError(e)}'),
              data: (s) => _SummaryGrid(summary: s),
            ),
            const SizedBox(height: AppSpacing.lg),
            _Timeline(
              value: summaryAsync,
              params: _params,
              showAll: _showAllEvents,
              sourceNameOf: (code) => findPriceSource(sources, code)?.name,
              onToggleAll: () => setState(() => _showAllEvents = !_showAllEvents),
              onSelect: (ev) => _setParams(selectEvent(_params, ev), scrollToList: true),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              key: _listHeaderKey,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(child: Text(changesTitle(_params.direction), style: AppTypography.sectionTitle)),
                if (list != null) Text('${list.total} kayıt', style: AppTypography.metadata),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_params.event != null) ...[
              ProductsNotice(
                tone: NoticeTone.info,
                text: 'Yalnızca bu güncellemenin değişiklikleri: ${eventScopeLabel(_params.event!)}',
                trailing: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: AppColors.info),
                    onPressed: () => _setParams(clearEvent(_params)),
                    child: const Text('Tüm dönemi göster'),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            ...listAsync.when(
              skipLoadingOnRefresh: true,
              loading: () => const [Padding(padding: EdgeInsets.all(AppSpacing.xl), child: LoadingState())],
              error: (e, _) => [ProductsNotice(tone: NoticeTone.danger, text: 'Liste alınamadı: ${productsLoadError(e)}')],
              data: (page) => [
                if (page.items.isEmpty)
                  AppCard(
                    child: Text(
                      page.total > 0 ? 'Bu sayfada kayıt yok.' : changesEmptyText(_params.direction),
                      style: AppTypography.metadata,
                      textAlign: TextAlign.center,
                    ),
                  ),
                for (final c in page.items)
                  _PriceChangeRow(
                    change: c,
                    sourceName: c.source == null ? null : findPriceSource(sources, c.source!)?.name,
                    showSourcePrice: canManage,
                    onTap: () => context.push(ProductsPaths.detail(c.productId)),
                  ),
                _ChangesFooter(
                  page: page,
                  onLoadMore: () => ref.read(priceChangesListProvider(listQ).notifier).loadMore(),
                ),
              ],
            ),
            if (attributions.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              for (final text in attributions) Text(text, style: AppTypography.helper),
            ],
          ],
        ),
      ),
    );
  }
}

class _SummarySkeleton extends StatelessWidget {
  const _SummarySkeleton();

  @override
  Widget build(BuildContext context) => const Column(
    children: [
      Row(
        children: [
          Expanded(child: SkeletonBox(height: 84)),
          SizedBox(width: AppSpacing.sm),
          Expanded(child: SkeletonBox(height: 84)),
        ],
      ),
      SizedBox(height: AppSpacing.sm),
      Row(
        children: [
          Expanded(child: SkeletonBox(height: 84)),
          SizedBox(width: AppSpacing.sm),
          Expanded(child: SkeletonBox(height: 84)),
        ],
      ),
    ],
  );
}

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({required this.summary});
  final PriceChangeSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final max = s.maxIncrease;
    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _StatTile(
                  label: 'ZAM GELEN ÜRÜN',
                  value: '${s.productsIncreased}',
                  valueColor: s.productsIncreased > 0 ? AppColors.danger : null,
                  detail: s.increasedCount != s.productsIncreased ? '${s.increasedCount} zam kaydı' : null,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _StatTile(
                  label: 'ORTALAMA ZAM',
                  value: s.avgIncreasePercent == null ? '—' : formatPricePercent(s.avgIncreasePercent!),
                  valueColor: (s.avgIncreasePercent ?? 0) != 0 ? AppColors.danger : null,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _StatTile(
                  label: 'EN YÜKSEK ZAM',
                  value: max == null ? '—' : formatPricePercent(max.changePercent),
                  valueColor: max == null ? null : AppColors.danger,
                  detail: max?.productName,
                  onTap: max == null ? null : () => context.push(ProductsPaths.detail(max.productId)),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _StatTile(
                  label: 'İNDİRİM',
                  value: '${s.decreasedCount}',
                  valueColor: s.decreasedCount > 0 ? AppColors.success : null,
                  detail: s.decreasedCount > 0 ? 'fiyatı düşen değişiklik' : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value, this.valueColor, this.detail, this.onTap});
  final String label;
  final String value;
  final Color? valueColor;
  final String? detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTypography.overline, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: AppSpacing.xs),
          Text(value, style: AppTypography.metricHero.copyWith(color: valueColor)),
          if (detail != null) ...[
            const SizedBox(height: 2),
            Text(
              detail!,
              style: AppTypography.helper.copyWith(
                color: onTap != null ? AppColors.gold : null,
                fontWeight: onTap != null ? FontWeight.w600 : null,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// Güncellemelerin zaman çizelgesi: her senkron / kâr oranı güncellemesi
/// bir olay, elle düzenlemeler gün başına. Olaya dokunmak listeyi o olayın
/// satırlarına daraltır.
class _Timeline extends StatelessWidget {
  const _Timeline({
    required this.value,
    required this.params,
    required this.showAll,
    required this.sourceNameOf,
    required this.onToggleAll,
    required this.onSelect,
  });

  final AsyncValue<PriceChangeSummary> value;
  final ZamlarParams params;
  final bool showAll;
  final String? Function(String code) sourceNameOf;
  final VoidCallback onToggleAll;
  final void Function(PriceChangeEvent ev) onSelect;

  @override
  Widget build(BuildContext context) {
    final summary = value.valueOrNull;
    final events = summary?.events ?? const <PriceChangeEvent>[];
    final visible = showAll ? events : events.take(_kCollapsedEvents).toList();
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
            child: Row(
              children: [
                const Expanded(child: Text('Güncellemeler', style: AppTypography.cardTitle)),
                if (summary != null) Text('${events.length} güncelleme', style: AppTypography.metadata),
              ],
            ),
          ),
          const Divider(),
          if (summary == null)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: value.hasError
                  ? const Text('Güncellemeler alınamadı.', style: AppTypography.metadata)
                  : const SkeletonBox(height: 48),
            )
          else if (events.isEmpty)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Text('Bu dönemde fiyat güncellemesi yok.', style: AppTypography.metadata),
            )
          else ...[
            for (var i = 0; i < visible.length; i++) ...[
              if (i > 0) const Divider(),
              _EventRow(
                event: visible[i],
                selected: isSelectedEvent(params.event, visible[i]),
                sourceName: visible[i].source == null ? null : sourceNameOf(visible[i].source!),
                onTap: () => onSelect(visible[i]),
              ),
            ],
            if (events.length > _kCollapsedEvents) ...[
              const Divider(),
              TextButton(
                onPressed: onToggleAll,
                child: Text(showAll ? 'Daha az göster' : 'Tümünü göster (${events.length})'),
              ),
            ],
            if (events.length >= kMaxPriceChangeEvents)
              const Padding(
                padding: EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
                child: Text(
                  'En yeni $kMaxPriceChangeEvents güncelleme gösteriliyor; daha eskileri için dönemi daralt.',
                  style: AppTypography.helper,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.selected, required this.sourceName, required this.onTap});
  final PriceChangeEvent event;
  final bool selected;
  final String? sourceName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ev = event;
    final avg = ev.avgChangePercent;
    final avgTone = eventAvgTone(ev);
    return Material(
      color: selected ? AppColors.gold.withValues(alpha: 0.10) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(eventTimeLabel(ev), style: AppTypography.cardTitle),
                        if (ev.source != null) SourceBadge(source: ev.source!, name: sourceName),
                        Text(eventReasonLabel(ev.reason), style: AppTypography.helper),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: eventCountsText(ev)),
                          if (avg != null) ...[
                            const TextSpan(text: ' · ort. '),
                            TextSpan(
                              // Ok ile yüzde aynı satırda kalsın (bölünmez boşluk).
                              text: formatChangePercent(avg, avgTone).replaceAll(' ', ' '),
                              style: TextStyle(color: changeToneColor(avgTone), fontWeight: FontWeight.w700),
                            ),
                          ],
                          if (ev.maxIncreasePercent != null && ev.increased > 1)
                            TextSpan(text: ' · en yüksek zam ${formatPricePercent(ev.maxIncreasePercent!)}'),
                        ],
                      ),
                      style: AppTypography.metadata,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              selected
                  ? const Icon(Icons.check_circle, color: AppColors.gold, size: 20, semanticLabel: 'Listede gösteriliyor')
                  : const Icon(Icons.chevron_right, color: AppColors.textMuted, semanticLabel: 'Ürünleri gör'),
            ],
          ),
        ),
      ),
    );
  }
}

class _PriceChangeRow extends StatelessWidget {
  const _PriceChangeRow({
    required this.change,
    required this.sourceName,
    required this.showSourcePrice,
    required this.onTap,
  });

  final PriceChange change;
  final String? sourceName;
  final bool showSourcePrice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = change;
    final tone = changeTone(c.oldPrice, c.newPrice);
    final meta = [c.unit, c.category].where((s) => s.isNotEmpty).join(' · ');
    // Tedarikçi fiyatları yalnızca döndüyse (products.manage) gösterilir.
    final showSource = showSourcePrice && hasSourcePrices(c.oldSourcePrice, c.newSourcePrice);
    return AppCard(
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(c.productName, style: AppTypography.cardTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: AppSpacing.sm),
              ChangePercentText(oldPrice: c.oldPrice, newPrice: c.newPrice, percent: c.changePercent),
            ],
          ),
          if (meta.isNotEmpty) Text(meta, style: AppTypography.metadata, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (c.source != null) SourceBadge(source: c.source!, name: sourceName),
              Text(reasonLabel(c.reason, c.oldPrice, c.newPrice), style: AppTypography.helper),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '${Formatters.money(c.oldPrice)} → ', style: AppTypography.metadata),
                      TextSpan(
                        text: Formatters.money(c.newPrice),
                        style: AppTypography.body.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ),
              Text(
                Formatters.signedMoney(c.changeAmount),
                style: AppTypography.body.copyWith(
                  color: changeToneColor(tone),
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (showSource) ...[
            const SizedBox(height: 2),
            Text(
              'Tedarikçi fiyatı: ${Formatters.money(c.oldSourcePrice!)} → ${Formatters.money(c.newSourcePrice!)}',
              style: AppTypography.helper,
            ),
          ],
          const SizedBox(height: 2),
          Text(formatChangeTime(c.changedAt), style: AppTypography.helper),
        ],
      ),
    );
  }
}

class _ChangesFooter extends StatelessWidget {
  const _ChangesFooter({required this.page, required this.onLoadMore});
  final PagedList<PriceChange> page;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (page.loadingMore) {
      return const Padding(padding: EdgeInsets.all(AppSpacing.lg), child: LoadingState());
    }
    if (page.loadMoreError != null) {
      return Column(
        children: [
          Text(productsLoadError(page.loadMoreError!), style: AppTypography.error, textAlign: TextAlign.center),
          TextButton(onPressed: onLoadMore, child: const Text('Tekrar Dene')),
        ],
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
