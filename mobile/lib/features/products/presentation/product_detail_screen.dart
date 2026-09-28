import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/products_providers.dart';
import '../domain/price_change.dart';
import '../domain/price_format.dart';
import '../domain/price_source.dart';
import '../domain/product.dart';
import 'products_paths.dart';
import 'widgets/products_common.dart';

/// Ürün detayı (web /admin/urunler/[id]): fiyat kaynağı + kaynak gösterimi,
/// ürün bilgileri, fiyat geçmişi. Ürün, fiyat geçmişi ve fiyat kaynağı
/// uçlarının üçü de products.read ister; düzenleme products.manage ile.
class ProductDetailScreen extends ConsumerWidget {
  const ProductDetailScreen({super.key, required this.productId});
  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canRead = productsCan(ref, ProductsPermissions.read);
    final canManage = productsCan(ref, ProductsPermissions.manage);
    final productAsync = canRead ? ref.watch(productDetailProvider(productId)) : null;
    final loaded = productAsync?.valueOrNull;
    return AppPageScaffold(
      title: Text(loaded?.name ?? 'Ürün', maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        if (canManage && loaded != null)
          IconButton(
            tooltip: 'Düzenle',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => context.push(ProductsPaths.edit(productId)),
          ),
      ],
      body: ProductsAccessGate(
        permission: ProductsPermissions.read,
        child: productAsync == null
            ? const SizedBox.shrink()
            : ProductsAsyncView(
                value: productAsync,
                onRetry: () async => ref.invalidate(productDetailProvider(productId)),
                data: (context, product) => _ProductDetailBody(product: product, canManage: canManage),
              ),
      ),
    );
  }
}

class _ProductDetailBody extends ConsumerWidget {
  const _ProductDetailBody({required this.product, required this.canManage});
  final Product product;
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = product;
    final sourcesAsync = ref.watch(priceSourcesProvider);
    final historyAsync = ref.watch(productPriceHistoryProvider(p.id));
    // Fiyat kaynağı yalnızca "listede yok" rozeti ve kaynak bilgisi için;
    // hatası sayfayı düşürmez.
    final ps = findPriceSource(sourcesAsync.valueOrNull, p.source);
    final missing = isMissingFromSource(p, ps);

    Future<void> refresh() async {
      ref.invalidate(productDetailProvider(p.id));
      ref.invalidate(productPriceHistoryProvider(p.id));
      ref.invalidate(priceSourcesProvider);
      try {
        await ref.read(productDetailProvider(p.id).future);
      } catch (_) {}
    }

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _Header(product: p, priceSource: ps, missing: missing),
          if (!canManage) ...[const SizedBox(height: AppSpacing.md), const ReadOnlyNotice(kProductReadOnly)],
          const SizedBox(height: AppSpacing.lg),
          _SourceCard(product: p, priceSource: ps, missing: missing, canManage: canManage),
          const SizedBox(height: AppSpacing.lg),
          _InfoCard(product: p, canManage: canManage),
          const SizedBox(height: AppSpacing.lg),
          _HistorySection(value: historyAsync, canManage: canManage),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.product, required this.priceSource, required this.missing});
  final Product product;
  final PriceSource? priceSource;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final p = product;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(p.name, style: AppTypography.pageTitle),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: [
            if (p.isManual)
              const StatusBadge(label: 'Elle eklendi', tone: StatusTone.muted)
            else
              SourceBadge(source: p.source, name: priceSource?.name),
            if (!p.isManual && missing) MissingFromSourceBadge(source: p.source, name: priceSource?.name),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            MoneyText(p.unitPrice, style: AppTypography.metricHero),
            if (p.unit.isNotEmpty) ...[
              const SizedBox(width: AppSpacing.xs),
              Text('/ ${p.unit}', style: AppTypography.metadata),
            ],
          ],
        ),
        const SizedBox(height: 2),
        const Text('Birim satış fiyatı', style: AppTypography.helper),
      ],
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.product,
    required this.priceSource,
    required this.missing,
    required this.canManage,
  });

  final Product product;
  final PriceSource? priceSource;
  final bool missing;
  final bool canManage;

  @override
  Widget build(BuildContext context) {
    final p = product;
    final ps = priceSource;
    if (p.isManual) {
      return const ProductsSectionCard(
        title: 'Fiyat Kaynağı',
        child: Text(
          'Elle eklenen ürün: tedarikçi güncellemeleri (Ulaş, Demir Profil) bu ürünün fiyatına dokunmaz.',
          style: AppTypography.metadata,
        ),
      );
    }
    final labels = sourceLabels(p.source, ps?.name);
    // Demir Profil'in kullanım koşulu kaynağın (ve liste ayının)
    // belirtilmesini istiyor; kaynak bilgisi alınamasa da site adı yazılır.
    final attribution = sourceAttribution(p.source, ps);
    final siteUrl = ps != null && isSafeSiteUrl(ps.siteUrl) ? ps.siteUrl : null;
    // Kâr oranı uygulanmamış fiyat: backend yalnızca products.manage'e döndürür.
    final sourcePrice = canManage ? p.sourcePrice : null;
    return ProductsSectionCard(
      title: 'Fiyat Kaynağı',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Önce tek cümlelik sonuç ve rakamlar; ayrıntılı açıklama isteyene
          // ("Nasıl çalışır?") -- iki uzun paragraf fiyat bilgisini ekranın
          // altına itiyordu.
          Text(
            'Fiyat ve kategori her ${labels.short} güncellemesinde listeden yeniden yazılır.',
            style: AppTypography.metadata.copyWith(height: 1.35),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (sourcePrice != null)
            ProductInfoRow(label: '${labels.short} fiyatı', value: Formatters.money(sourcePrice)),
          ProductInfoRow(
            label: 'Listede son görülme',
            value: p.sourceSyncedAt == null ? 'Henüz güncellenmedi' : formatSyncTime(p.sourceSyncedAt!),
          ),
          if (ps != null && ps.vatNote.isNotEmpty)
            ProductInfoRow(label: 'Fiyat esası', value: ps.vatNote, valueStyle: AppTypography.body),
          _HowItWorks(
            paragraphs: [
              'Bu ürünün fiyatı ve kategorisi her ${labels.short} güncellemesinde ${labels.short} fiyat listesinden '
                  'yeniden yazılır; elle yapılan fiyat ve kategori değişiklikleri bir sonraki güncellemede kaybolur.'
                  '${canManage ? ' Satış fiyatını kalıcı değiştirmek için Fiyat Kaynakları ekranındaki kâr oranı ayarlarını kullan.' : ''}',
              'Ürün, ${labels.short} listesiyle adı ve birimi üzerinden eşleşir. Ad veya birim değişirse bağlantı kopar: '
                  'bir sonraki güncelleme ${labels.short} ürününü yeni bir kayıt olarak ekler, bu kayıt da '
                  '"${labels.short} listesinde yok" olarak kalır ve fiyatı artık güncellenmez.',
            ],
          ),
          if (attribution.isNotEmpty || siteUrl != null) ...[
            const Divider(),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.xs,
              children: [
                if (attribution.isNotEmpty) Text(attribution, style: AppTypography.helper),
                if (siteUrl != null) SiteLink(url: siteUrl),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Katlanır "Nasıl çalışır?" açıklaması (varsayılan kapalı).
class _HowItWorks extends StatefulWidget {
  const _HowItWorks({required this.paragraphs});
  final List<String> paragraphs;

  @override
  State<_HowItWorks> createState() => _HowItWorksState();
}

class _HowItWorksState extends State<_HowItWorks> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: () => setState(() => _open = !_open),
            icon: Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18),
            label: const Text('Nasıl çalışır?'),
          ),
        ),
        if (_open)
          for (final text in widget.paragraphs)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Text(text, style: AppTypography.metadata.copyWith(height: 1.35)),
            ),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.product, required this.canManage});
  final Product product;
  final bool canManage;

  @override
  Widget build(BuildContext context) {
    final p = product;
    return ProductsSectionCard(
      title: 'Ürün Bilgileri',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProductInfoRow(label: 'Birim', value: p.unit.isEmpty ? '—' : p.unit),
          ProductInfoRow(label: 'Kategori', value: p.category.isEmpty ? '—' : p.category),
          ProductInfoRow(
            label: 'Açıklama',
            value: p.description.isEmpty ? '—' : p.description,
            valueStyle: AppTypography.body,
          ),
          if (canManage) ...[
            const SizedBox(height: AppSpacing.md),
            SecondaryButton(
              label: 'Düzenle',
              icon: Icons.edit_outlined,
              onPressed: () => context.push(ProductsPaths.edit(p.id)),
            ),
          ],
        ],
      ),
    );
  }
}

class _HistorySection extends StatelessWidget {
  const _HistorySection({required this.value, required this.canManage});
  final AsyncValue<List<PriceHistoryEntry>> value;
  final bool canManage;

  @override
  Widget build(BuildContext context) {
    return ProductsSectionCard(
      title: 'Fiyat Geçmişi',
      child: value.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.gold)),
        ),
        error: (e, _) => Text('Fiyat geçmişi alınamadı: ${productsLoadError(e)}', style: AppTypography.metadata),
        data: (history) {
          if (history.isEmpty) {
            return const Text('Bu ürünün fiyatı henüz hiç değişmedi.', style: AppTypography.metadata);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < history.length; i++) ...[
                if (i > 0) const Divider(height: AppSpacing.xl),
                _HistoryEntryRow(entry: history[i], canManage: canManage),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _HistoryEntryRow extends StatelessWidget {
  const _HistoryEntryRow({required this.entry, required this.canManage});
  final PriceHistoryEntry entry;
  final bool canManage;

  @override
  Widget build(BuildContext context) {
    final h = entry;
    // Tedarikçi fiyatları yalnızca products.manage'e döner (diğerlerinde null).
    final showSource = canManage && hasSourcePrices(h.oldSourcePrice, h.newSourcePrice);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(reasonLabel(h.reason, h.oldPrice, h.newPrice), style: AppTypography.cardTitle),
                  if (h.source != null) SourceBadge(source: h.source!),
                ],
              ),
            ),
            ChangePercentText(
              oldPrice: h.oldPrice,
              newPrice: h.newPrice,
              percent: changePercentOf(h.oldPrice, h.newPrice),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            Expanded(child: Text(formatChangeTime(h.changedAt), style: AppTypography.metadata)),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${Formatters.money(h.oldPrice)} → ', style: AppTypography.metadata),
                  TextSpan(
                    text: Formatters.money(h.newPrice),
                    style: AppTypography.metadata.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (showSource) ...[
          const SizedBox(height: 2),
          Text(
            'Tedarikçi fiyatı: ${Formatters.money(h.oldSourcePrice!)} → ${Formatters.money(h.newSourcePrice!)}',
            style: AppTypography.helper,
          ),
        ],
        if (h.note.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(h.note, style: AppTypography.helper),
        ],
      ],
    );
  }
}
