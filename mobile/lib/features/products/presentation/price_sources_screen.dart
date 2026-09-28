import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/products_providers.dart';
import '../domain/price_change.dart';
import '../domain/price_format.dart';
import '../domain/price_source.dart';
import 'price_source_settings_sheet.dart';
import 'products_paths.dart';
import 'widgets/products_common.dart';

/// Fiyat Kaynakları (web Ürünler sayfasındaki "Fiyat Kaynağı: …" kartları):
/// GET /products/price-sources'un her kaynağı için bir kart. Durum
/// products.read olan herkese görünür; "…'tan Güncelle" ve kâr oranı
/// ayarları yalnızca products.manage ile (backend oranları da yalnızca bu
/// izne döndürür).
class PriceSourcesScreen extends ConsumerWidget {
  const PriceSourcesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const AppPageScaffold(
      title: Text('Fiyat Kaynakları'),
      body: ProductsAccessGate(permission: ProductsPermissions.read, child: _PriceSourcesBody()),
    );
  }
}

class _PriceSourcesBody extends ConsumerWidget {
  const _PriceSourcesBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sourcesAsync = ref.watch(priceSourcesProvider);
    final canManage = productsCan(ref, ProductsPermissions.manage);

    Future<void> refresh() async {
      ref.invalidate(priceSourcesProvider);
      try {
        await ref.read(priceSourcesProvider.future);
      } catch (_) {}
    }

    return RefreshIndicator(
      onRefresh: refresh,
      child: ProductsAsyncView(
        value: sourcesAsync,
        onRetry: refresh,
        data: (context, sources) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            if (!canManage) ...[
              const ReadOnlyNotice(kPriceSourcesReadOnly),
              const SizedBox(height: AppSpacing.lg),
            ],
            if (sources.isEmpty)
              const EmptyStateView(message: 'Fiyat kaynağı bulunamadı.', icon: Icons.cloud_off_outlined),
            for (final ps in sources) ...[
              PriceSourceCard(key: ValueKey(ps.source), priceSource: ps, canManage: canManage),
              const SizedBox(height: AppSpacing.lg),
            ],
          ],
        ),
      ),
    );
  }
}

class PriceSourceCard extends ConsumerStatefulWidget {
  const PriceSourceCard({super.key, required this.priceSource, required this.canManage});
  final PriceSource priceSource;
  final bool canManage;

  @override
  ConsumerState<PriceSourceCard> createState() => _PriceSourceCardState();
}

class _PriceSourceCardState extends ConsumerState<PriceSourceCard> {
  bool _syncing = false;
  ({NoticeTone tone, String text})? _notice;

  PriceSource get ps => widget.priceSource;
  SourceLabels get labels => sourceLabels(ps.source, ps.name);

  Future<void> _sync() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${labels.ablative} güncellensin mi?'),
        content: Text(
          '${labels.short} fiyat listesi indirilip katalogdaki ${labels.short} ürünleri güncellenecek. '
          'Elle eklenen ürünlere dokunulmaz; listeden düşen ürünler silinmez.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Güncelle')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _syncing = true;
      _notice = null;
    });
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final res = await ref.read(productsRepositoryProvider).syncPriceSource(ps.source);
      if (mounted) setState(() => _notice = (tone: NoticeTone.success, text: syncSuccessMessage(res, labels)));
      invalidateProductData(container.invalidate);
    } on ApiException catch (e) {
      final text = e.isForbidden ? kProductsManageDenied : priceSyncErrorMessage(e.statusCode, e.message, labels);
      if (mounted) setState(() => _notice = (tone: NoticeTone.danger, text: text));
      // Backend başarısız indirmeyi / kısa listeyi / uygulama hatasını
      // last_status/last_error'a yazar -- kartın durumu da tazelensin.
      if (syncErrorUpdatesStatus(e.statusCode)) container.invalidate(priceSourcesProvider);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _openSettings() async {
    final result = await showPriceSourceSettingsSheet(context, ps);
    if (result == null || !mounted) return;
    setState(() {
      _notice = (
        tone: NoticeTone.success,
        text: settingsSavedMessage(result.recomputed, result.priceSource.lastSyncedAt, labels.short),
      );
    });
    invalidateProductData(ref.invalidate);
  }

  @override
  Widget build(BuildContext context) {
    final name = labels.short;
    // Backend oranı products.manage olmayana zaten null döndürür.
    final markupPercent = widget.canManage ? ps.markupPercent : null;
    final overrideCount = ps.categoryMarkups?.length ?? 0;
    final changesText = lastChangesMessage(ps.lastChanges);
    final today = ref.watch(productsTodayProvider);

    return ProductsSectionCard(
      title: 'Fiyat Kaynağı: ${ps.name}',
      trailing: _statusBadge(ps.lastStatus),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (isSafeSiteUrl(ps.siteUrl)) SiteLink(url: ps.siteUrl),
              if (ps.listLabel.isNotEmpty)
                Text.rich(
                  TextSpan(
                    children: [
                      const TextSpan(text: 'Liste dönemi: '),
                      TextSpan(
                        text: ps.listLabel,
                        style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  style: AppTypography.helper,
                ),
            ],
          ),
          if (ps.vatNote.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text('Fiyat esası: ${ps.vatNote}', style: AppTypography.helper),
          ],
          // Kaynağın kullanım koşulu kaynak ve liste ayının belirtilmesini
          // istiyor (Demir Profil); backend zorunlu değilse "" döndürür.
          if (ps.attribution.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(ps.attribution, style: AppTypography.helper),
          ],
          const SizedBox(height: AppSpacing.md),
          ProductInfoRow(
            label: 'Son başarılı güncelleme',
            value: ps.lastSyncedAt == null ? 'Hiç çekilmedi' : formatSyncTime(ps.lastSyncedAt!),
          ),
          ProductInfoRow(label: 'Otomatik güncelleme', value: ps.autoSync ? 'Açık · her gece 00:05' : 'Kapalı'),
          ProductInfoRow(
            label: 'Katalogdaki $name ürünü',
            value: ps.missingCount > 0
                ? '${ps.productCount} (${ps.missingCount} tanesi son listede yok)'
                : '${ps.productCount}',
          ),
          if (markupPercent != null)
            ProductInfoRow(
              label: 'Kâr oranı',
              value: overrideCount > 0
                  ? '${formatPricePercent(markupPercent)} · $overrideCount kategoride özel oran'
                  : formatPricePercent(markupPercent),
            ),
          if (ps.lastStatus == PriceSyncStatus.failed) ...[
            const SizedBox(height: AppSpacing.sm),
            ProductsNotice(
              tone: NoticeTone.danger,
              text:
                  'Son deneme başarısız${ps.lastError.isNotEmpty ? ': ${asSentence(ps.lastError)}' : '.'} '
                  'Ürünlerde değişiklik yapılmadı'
                  '${ps.lastSyncedAt != null ? '; aşağıdaki sayılar son başarılı güncellemeye aittir.' : '.'}',
            ),
          ],
          if (ps.lastSyncedAt != null) ...[
            const SizedBox(height: AppSpacing.md),
            const Text('SON GÜNCELLEMENİN SONUCU', style: AppTypography.overline),
            const SizedBox(height: AppSpacing.sm),
            _CountsGrid(counts: ps.lastResult),
          ],
          if (changesText != null) ...[
            const SizedBox(height: AppSpacing.md),
            _LastChangesRow(
              text: changesText,
              hasIncrease: (ps.lastChanges?.increased ?? 0) > 0,
              // Satırın anlattığı senkronu kapsar; fiyat değiştirdiyse liste o
              // senkronun satırlarını gösterir.
              onOpen: () => context.push(ProductsPaths.priceChangesWith(sourceHistoryParams(ps, today).toQuery())),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          if (widget.canManage)
            _Bullet(
              'Satış fiyatı = $name fiyatı × (1 + kâr oranı). Kâr oranı değişince $name fiyatı bilinen (en az bir '
              'kez ${labels.ablative} güncellenmiş) ürünlerin fiyatı hemen yeniden hesaplanır.'
              '${ps.lastSyncedAt == null ? ' Henüz başarılı bir $name güncellemesi olmadığı için kaydedilen oranlar ilk güncellemede uygulanır.' : ''}',
            ),
          const _Bullet('Elle eklenen ürünlere ve diğer tedarikçilerden gelen ürünlere dokunulmaz.'),
          _Bullet('$name listesinden düşen ürünler silinmez; "$name listesinde yok" olarak işaretlenir.'),
          if (_notice != null) ...[
            const SizedBox(height: AppSpacing.md),
            ProductsNotice(tone: _notice!.tone, text: _notice!.text),
          ],
          if (widget.canManage) ...[
            const SizedBox(height: AppSpacing.md),
            // İkonsuz: uzun kaynak adı ("Demir Profil'den Güncelle") büyük
            // yazı boyutunda satıra sığmazsa metin sarar, taşmaz.
            PrimaryButton(
              label: '${labels.ablative} Güncelle',
              loading: _syncing,
              onPressed: _sync,
            ),
            const SizedBox(height: AppSpacing.sm),
            SecondaryButton(
              label: 'Kâr oranı ayarları',
              icon: Icons.tune,
              onPressed: _syncing ? null : _openSettings,
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusBadge(String status) => switch (status) {
    PriceSyncStatus.success => const StatusBadge(label: 'Başarılı', tone: StatusTone.success),
    PriceSyncStatus.failed => const StatusBadge(label: 'Başarısız', tone: StatusTone.danger),
    _ => const StatusBadge(label: 'Hiç çekilmedi', tone: StatusTone.muted),
  };
}

class _CountsGrid extends StatelessWidget {
  const _CountsGrid({required this.counts});
  final PriceSyncCounts counts;

  @override
  Widget build(BuildContext context) {
    final items = [
      ('Toplam', counts.total),
      ('Yeni', counts.created),
      ('Güncellenen', counts.updated),
      ('Değişmeyen', counts.unchanged),
      ('Listede artık olmayan', counts.missing),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final half = (constraints.maxWidth - AppSpacing.sm) / 2;
        return Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final (i, (label, value)) in items.indexed)
              Container(
                // İki sütun; tek kalan son kutu ("Listede artık olmayan")
                // satırın tamamını alır, uzun etiketi kesilmez.
                width: i == items.length - 1 && items.length.isOdd ? constraints.maxWidth : half,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: AppTypography.helper, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text('$value', style: AppTypography.metricPrimary.copyWith(fontSize: 18)),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

class _LastChangesRow extends StatelessWidget {
  const _LastChangesRow({required this.text, required this.hasIncrease, required this.onOpen});
  final String text;
  final bool hasIncrease;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.xs, 0),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(Icons.trending_up, size: 18, color: hasIncrease ? AppColors.danger : AppColors.textMuted),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(text, style: AppTypography.metadata.copyWith(color: AppColors.textPrimary))),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.history, size: 16),
              label: const Text('Zam Geçmişi'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('•  ', style: AppTypography.helper),
          Expanded(child: Text(text, style: AppTypography.helper.copyWith(height: 1.35))),
        ],
      ),
    );
  }
}
