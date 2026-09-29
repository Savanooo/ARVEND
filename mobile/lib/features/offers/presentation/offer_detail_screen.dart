import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/offers_providers.dart';
import '../domain/offer.dart';
import '../history/offer_history_routes.dart' show OfferHistorySection, invalidateOfferHistory;

class OfferDetailScreen extends ConsumerStatefulWidget {
  const OfferDetailScreen({super.key, required this.offerId});
  final String offerId;

  @override
  ConsumerState<OfferDetailScreen> createState() => _OfferDetailScreenState();
}

class _OfferDetailScreenState extends ConsumerState<OfferDetailScreen> {
  bool _converting = false;
  bool _creatingLink = false;
  bool _sendingEmail = false;

  String get offerId => widget.offerId;

  // Yazmalar kapsayıcının `invalidate`'ini ilk await'ten ÖNCE alır: istek
  // sürerken geri basılıp ekran kapansa da liste/geçmiş tazelenir
  // (`WidgetRef` dispose sonrası StateError atardı).
  Future<void> _setStatus(String status) async {
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      await ref.read(offersRepositoryProvider).updateStatus(offerId, status);
      invalidate(offerDetailProvider(offerId));
      invalidate(offersListProvider(''));
      invalidate(offerRevisionsProvider(offerId));
      invalidateOfferHistory(invalidate, offerId);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _reviseAndEdit() async {
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      final revised = await ref.read(offersRepositoryProvider).revise(offerId);
      invalidate(offerDetailProvider(offerId));
      invalidate(offersListProvider(''));
      invalidate(offerRevisionsProvider(offerId));
      invalidateOfferHistory(invalidate, offerId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Revizyon #${revised.revisionNo} oluşturuldu')),
      );
      context.push('/teklifler/${revised.id}/duzenle');
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _convert() async {
    setState(() => _converting = true);
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      final result = await ref.read(offersRepositoryProvider).convertToProject(offerId);
      invalidate(offerLinkedProjectIdProvider(offerId));
      invalidateOfferHistory(invalidate, offerId);
      if (!mounted) return;
      final projectId = result['id'] as String?;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Proje oluşturuldu')));
      if (projectId != null) {
        context.go('/projeler/$projectId');
      } else {
        context.go('/projeler');
      }
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  Future<void> _createShareLink() async {
    setState(() => _creatingLink = true);
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      final link = await ref.read(offersRepositoryProvider).createShareLink(offerId);
      // Link oluşturma bir olay (share_link_created) üretir.
      invalidateOfferHistory(invalidate, offerId);
      if (!mounted) return;
      // Ağ çağrısı bitti -- diyalog açık kaldığı sürece (kullanıcı kopyala/
      // kapat'a basana kadar) buton sonsuza dek "yükleniyor" görünmesin.
      setState(() => _creatingLink = false);
      final url = '${AppConfig.apiBaseUrl}/paylas/${link.token}';
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Paylaşım Linki'),
          content: SelectableText(url),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Kapat')),
            FilledButton.icon(
              icon: const Icon(Icons.copy_outlined, size: 18),
              label: const Text('Kopyala'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: url));
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link kopyalandı')));
              },
            ),
          ],
        ),
      );
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _creatingLink = false);
    }
  }

  Future<void> _sendEmail() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Teklifi e-postayla gönder'),
        content: const Text('Teklif, kayıtlı müşteri e-posta adresine paylaşım linkiyle birlikte gönderilecek.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Gönder')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _sendingEmail = true);
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      await ref.read(offersRepositoryProvider).sendEmail(offerId);
      invalidate(offerDetailProvider(offerId));
      invalidate(offersListProvider(''));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('E-posta gönderildi')));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      // Başarısız gönderim de "Mail Geçmişi"ne (failed) düşer -- her iki
      // durumda da geçmiş tazelenir.
      invalidateOfferHistory(invalidate, offerId);
      if (mounted) setState(() => _sendingEmail = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final offerAsync = ref.watch(offerDetailProvider(offerId));
    final revisionsAsync = ref.watch(offerRevisionsProvider(offerId));
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canReadInternal = user?.hasPermission(kPermOffersInternalPricingRead) ?? false;
    final canConvert = user?.hasPermission(kPermProjectsCreate) ?? false;
    // İzni olmayan VEYA henüz "kabul edildi" durumuna gelmemiş bir teklif
    // İÇİN bu sorgu hiç atılmaz -- yalnızca kabul edilmiş teklifler
    // dönüştürülebilir, gereksiz bir /offers/{id}/project isteği YOK.
    final canHaveProject = canConvert && offerAsync.valueOrNull?.status == Offer.statusKabulEdildi;
    final linkedProjectIdAsync =
        canHaveProject ? ref.watch(offerLinkedProjectIdProvider(offerId)) : const AsyncValue<String?>.data(null);

    return AppPageScaffold(
      title: offerAsync.maybeWhen(data: (o) => Text(o.offerNo), orElse: () => const Text('Teklif')),
      actions: [
        offerAsync.maybeWhen(
          data: (o) => o.isEditable
              ? IconButton(
                  tooltip: 'Düzenle',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => context.push('/teklifler/$offerId/duzenle'),
                )
              : const SizedBox.shrink(),
          orElse: () => const SizedBox.shrink(),
        ),
      ],
      body: AsyncStateView<Offer>(
        value: offerAsync,
        onRetry: () async => ref.invalidate(offerDetailProvider(offerId)),
        data: (context, offer) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(offerDetailProvider(offerId));
            ref.invalidate(offerRevisionsProvider(offerId));
            ref.invalidate(offerLinkedProjectIdProvider(offerId));
            invalidateOfferHistory(ref.invalidate, offerId);
          },
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  StatusRegistry.build(offer.status, StatusRegistry.offer),
                  MoneyText(offer.grandTotal, style: AppTypography.pageTitle),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text('Revizyon #${offer.revisionNo}', style: AppTypography.metadata),
              const SizedBox(height: AppSpacing.lg),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(offer.customerName, style: AppTypography.cardTitle),
                    if (offer.customerPhone.isNotEmpty) Text(offer.customerPhone, style: AppTypography.body),
                    if (offer.customerEmail.isNotEmpty) Text(offer.customerEmail, style: AppTypography.body),
                    if (offer.customerAddress.isNotEmpty) Text(offer.customerAddress, style: AppTypography.body),
                    const Divider(height: AppSpacing.xl),
                    _KV('Teklif Tarihi', Formatters.date(offer.offerDate)),
                    _KV('Geçerlilik', Formatters.date(offer.validUntil)),
                    if (offer.notes.isNotEmpty) _KV('Notlar', offer.notes),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              const AppSectionHeader(title: 'Kalemler'),
              const SizedBox(height: AppSpacing.sm),
              ...offer.items.map((item) => _ItemCard(item: item, showInternal: canReadInternal)),
              AppCard(
                margin: const EdgeInsets.only(top: AppSpacing.sm),
                child: Column(
                  children: [
                    _KV('Ara Toplam', Formatters.money(offer.subtotal)),
                    _KV('KDV (%${offer.vatRate.toStringAsFixed(0)})', Formatters.money(offer.vatAmount)),
                    const Divider(),
                    _KV('Genel Toplam', Formatters.money(offer.grandTotal), bold: true),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              const AppSectionHeader(title: 'Revizyon Geçmişi'),
              const SizedBox(height: AppSpacing.sm),
              AsyncStateView<List<OfferRevision>>(
                value: revisionsAsync,
                onRetry: () async => ref.invalidate(offerRevisionsProvider(offerId)),
                isEmpty: (r) => r.isEmpty,
                emptyBuilder: (_) => const AppCard(child: Text('Henüz revizyon yok', style: AppTypography.metadata)),
                data: (context, revs) {
                  final sorted = [...revs]..sort((a, b) => b.revisionNo.compareTo(a.revisionNo));
                  return Column(
                    children: sorted.map((r) {
                      final isCurrent = r.revisionNo == offer.revisionNo;
                      return AppCard(
                        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                        onTap: () => context.push('/teklifler/$offerId/revizyonlar/${r.id}'),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Revizyon #${r.revisionNo}${isCurrent ? ' (güncel)' : ''}',
                                    style: AppTypography.cardTitle,
                                  ),
                                  Text(
                                    '${Formatters.dateTime(r.createdAt)} · ${Formatters.money(r.grandTotal)}',
                                    style: AppTypography.metadata,
                                  ),
                                ],
                              ),
                            ),
                            StatusRegistry.build(r.status, StatusRegistry.offer),
                          ],
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
              // Web teklif detayındaki "Aktivite / Zaman Çizelgesi" + "Mail
              // Geçmişi" (görüntülenme özeti dahil); tamamı /teklifler/:id/gecmis.
              const SizedBox(height: AppSpacing.xl),
              OfferHistorySection(offerId: offerId),
              const SizedBox(height: AppSpacing.xl),
              if (offer.isEditable)
                PrimaryButton(
                  label: 'Gönderildi Olarak İşaretle',
                  onPressed: () => _setStatus(Offer.statusGonderildi),
                ),
              if (offer.status == Offer.statusGonderildi)
                Row(
                  children: [
                    Expanded(
                      child: PrimaryButton(
                        label: 'Kabul Edildi',
                        onPressed: () => _setStatus(Offer.statusKabulEdildi),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: SecondaryButton(
                        label: 'Reddedildi',
                        onPressed: () => _setStatus(Offer.statusReddedildi),
                      ),
                    ),
                  ],
                ),
              if (offer.status == Offer.statusKabulEdildi && canConvert) ...[
                const SizedBox(height: AppSpacing.sm),
                linkedProjectIdAsync.maybeWhen(
                  data: (projectId) => projectId != null
                      ? SecondaryButton(
                          icon: Icons.business_center_outlined,
                          label: 'Projeyi Görüntüle',
                          onPressed: () => context.push('/projeler/$projectId'),
                        )
                      : PrimaryButton(
                          icon: Icons.business_center_outlined,
                          label: 'Projeye Dönüştür',
                          loading: _converting,
                          onPressed: _convert,
                        ),
                  orElse: () => const SizedBox.shrink(),
                ),
              ],
              if (offer.canRevise || !offer.isPassive) ...[
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    if (offer.canRevise)
                      SecondaryButton(icon: Icons.refresh, label: 'Revize Et ve Düzenle', onPressed: _reviseAndEdit),
                    if (!offer.isPassive) ...[
                      SecondaryButton(
                        icon: Icons.ios_share_outlined,
                        label: 'Paylaşım Linki',
                        loading: _creatingLink,
                        onPressed: _createShareLink,
                      ),
                      SecondaryButton(
                        icon: Icons.mail_outline,
                        label: 'E-posta Gönder',
                        loading: _sendingEmail,
                        onPressed: _sendEmail,
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.item, required this.showInternal});
  final OfferItem item;
  final bool showInternal;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(item.productName, style: AppTypography.cardTitle)),
              MoneyText(item.lineTotal, style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
          Text(
            '${item.quantity.toStringAsFixed(item.quantity.truncateToDouble() == item.quantity ? 0 : 2)} ${item.unit} × ${Formatters.money(item.unitPrice)}'
            '${item.sectionLabel != null ? '  ·  ${item.sectionLabel}' : ''}',
            style: AppTypography.metadata,
          ),
          if (showInternal && item.hasInternalPricing) ...[
            const SizedBox(height: AppSpacing.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.navDark.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(AppRadius.control),
                border: Border.all(color: AppColors.navDark.withValues(alpha: 0.16)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.lock_outline, size: 14, color: AppColors.navDark),
                      const SizedBox(width: 6),
                      Text('İç Fiyatlandırma', style: AppTypography.helper.copyWith(
                          color: AppColors.navDark, fontWeight: FontWeight.w700)),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 20, bottom: 4),
                    child: Text('Müşteri görmez', style: AppTypography.helper),
                  ),
                  if (item.internalSubcontractCost != null)
                    Text('İç maliyet: ${Formatters.money(item.internalSubcontractCost!)}',
                        style: AppTypography.helper),
                  Text(
                    'Mod: ${item.pricingMode == OfferItem.pricingModeMarkup ? 'Markup' : item.pricingMode == OfferItem.pricingModeManual ? 'Manuel' : '-'}',
                    style: AppTypography.helper,
                  ),
                  if (item.pricingMode == OfferItem.pricingModeMarkup && item.markupPercent != null)
                    Text('Markup: %${item.markupPercent!.toStringAsFixed(2)}', style: AppTypography.helper),
                  if (item.expectedProfit != null)
                    Text('Beklenen kâr: ${Formatters.money(item.expectedProfit!)}', style: AppTypography.helper),
                  if (item.effectiveMarkupPercent != null)
                    Text('Efektif markup: %${item.effectiveMarkupPercent!.toStringAsFixed(2)}',
                        style: AppTypography.helper),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _KV extends StatelessWidget {
  const _KV(this.label, this.value, {this.bold = false});
  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTypography.metadata),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: bold
                  ? AppTypography.metricPrimary.copyWith(fontSize: 17)
                  : AppTypography.body.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
