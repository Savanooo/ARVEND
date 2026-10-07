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
import 'offer_pdf.dart';
import '../../../core/widgets/app_sheet.dart';

class OfferDetailScreen extends ConsumerStatefulWidget {
  const OfferDetailScreen({super.key, required this.offerId});
  final String offerId;

  @override
  ConsumerState<OfferDetailScreen> createState() => _OfferDetailScreenState();
}

class _OfferDetailScreenState extends ConsumerState<OfferDetailScreen> {
  bool _creatingLink = false;
  bool _sendingEmail = false;
  bool _downloadingPdf = false;

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

  /// Durum düğmeleri tek dokunuşla geri alınamaz sonuç doğurur: "Kabul
  /// Edildi" teklifi KALICI olarak kilitler (sunucu `ErrOfferLocked`; bir
  /// daha düzenlenemez, revize edilemez, durumu değişmez), "Reddedildi" ve
  /// "Gönderildi" ise yalnızca yeni bir revizyonla düzeltilebilir. Bu yüzden
  /// her biri onay ister -- yanlışlıkla dokunmak teklifi kilitlemesin.
  Future<void> _confirmAndSetStatus(
    String status, {
    required String title,
    required String message,
    required String confirmLabel,
    bool danger = false,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          TextButton(
            key: const ValueKey('offer-status-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            style: danger ? TextButton.styleFrom(foregroundColor: AppColors.danger) : null,
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _setStatus(status);
  }

  /// Teklifin PDF'ini indirir (`GET /offers/{id}/pdf`) ve cihazın PDF
  /// görüntüleyicisiyle açar -- müşteriye elden/WhatsApp ile iletmek için.
  Future<void> _downloadPdf(Offer offer) async {
    if (_downloadingPdf) return;
    setState(() => _downloadingPdf = true);
    final opener = ref.read(offerPdfOpenerProvider);
    try {
      final bytes = await ref.read(offersRepositoryProvider).pdfBytes(offer.id);
      final error = await opener(offer.pdfFilename, bytes);
      if (error != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      }
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } on Exception catch (_) {
      // Dosya yazılamadı / görüntüleyici eklentisi yok: çökme yok.
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PDF açılamadı.')));
    } finally {
      if (mounted) setState(() => _downloadingPdf = false);
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

  /// Web'deki projeye-donustur formunun karşılığı: ad / tip / tarihler /
  /// açıklama sorulur, istek formun içinden atılır (hata olursa form açık
  /// kalır, girilenler kaybolmaz). Eskiden tek dokunuşla boş değerlerle
  /// dönüştürülüyordu.
  Future<void> _convert(Offer offer) async {
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    final result = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ConvertToProjectSheet(offer: offer),
    );
    if (result == null) return;
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
  }

  Future<void> _createShareLink() async {
    setState(() => _creatingLink = true);
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      final link = await ref.read(offersRepositoryProvider).createShareLink(offerId);
      // Link oluşturma bir olay (share_link_created) üretir.
      invalidateOfferHistory(invalidate, offerId);
      invalidate(offerShareLinksProvider(offerId));
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

  Future<void> _delete(Offer offer) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Teklifi Sil'),
        content: Text('${offer.offerNo} (${offer.customerName}) silinsin mi? Bu işlem geri alınamaz.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      await ref.read(offersRepositoryProvider).delete(offerId);
      invalidate(offersListProvider(''));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${offer.offerNo} silindi')));
      context.go('/teklifler');
    } on ApiException catch (e) {
      // Kabul edilmiş teklif backend'de de reddedilir; mesaj olduğu gibi.
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
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
    final canUpdate = user?.hasPermission(kPermOffersUpdate) ?? false;
    final canDelete = user?.hasPermission(kPermOffersDelete) ?? false;
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
          data: (o) => IconButton(
            key: const ValueKey('offer-pdf-appbar'),
            tooltip: 'PDF İndir',
            icon: _downloadingPdf
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.picture_as_pdf_outlined),
            onPressed: _downloadingPdf ? null : () => _downloadPdf(o),
          ),
          orElse: () => const SizedBox.shrink(),
        ),
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
        // Kabul edilmiş teklif silinemez (backend ErrOfferAccepted) -- seçenek
        // hiç sunulmaz; web'deki "Sil" düğmesinin karşılığı.
        if (canDelete)
          offerAsync.maybeWhen(
            data: (o) => o.status == Offer.statusKabulEdildi
                ? const SizedBox.shrink()
                : PopupMenuButton<String>(
                    tooltip: 'Diğer işlemler',
                    onSelected: (v) {
                      if (v == 'sil') _delete(o);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'sil',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.delete_outline, color: AppColors.danger),
                          title: Text('Teklifi Sil', style: TextStyle(color: AppColors.danger)),
                        ),
                      ),
                    ],
                  ),
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
                  MoneyText(offer.grandTotal, currency: offer.currency, style: AppTypography.pageTitle),
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
              ...offer.items.map((item) => _ItemCard(item: item, showInternal: canReadInternal, currency: offer.currency)),
              AppCard(
                margin: const EdgeInsets.only(top: AppSpacing.sm),
                child: Column(
                  children: [
                    _KV('Ara Toplam', Formatters.money(offer.subtotal, currency: offer.currency)),
                    _KV('KDV (%${offer.vatRate.toStringAsFixed(0)})', Formatters.money(offer.vatAmount, currency: offer.currency)),
                    const Divider(),
                    _KV('Genel Toplam', Formatters.money(offer.grandTotal, currency: offer.currency), bold: true),
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
                                    '${Formatters.dateTime(r.createdAt)} · ${Formatters.money(r.grandTotal, currency: r.currency)}',
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
              _ShareLinksSection(offerId: offerId, canRevoke: canUpdate),
              const SizedBox(height: AppSpacing.xl),
              OfferHistorySection(offerId: offerId),
              const SizedBox(height: AppSpacing.xl),
              if (offer.isEditable)
                PrimaryButton(
                  label: 'Gönderildi Olarak İşaretle',
                  onPressed: () => _confirmAndSetStatus(
                    Offer.statusGonderildi,
                    title: 'Gönderildi Olarak İşaretle',
                    message: '${offer.offerNo} gönderildi olarak işaretlensin mi? Bu revizyon artık '
                        'düzenlenemez; değişiklik için yeni bir revizyon gerekir.',
                    confirmLabel: 'İşaretle',
                  ),
                ),
              if (offer.status == Offer.statusGonderildi)
                Row(
                  children: [
                    Expanded(
                      child: PrimaryButton(
                        label: 'Kabul Edildi',
                        onPressed: () => _confirmAndSetStatus(
                          Offer.statusKabulEdildi,
                          title: 'Teklif Kabul Edildi',
                          message: '${offer.offerNo} kabul edildi olarak işaretlensin mi? Kabul edilen teklif '
                              'KALICI olarak kilitlenir: bir daha düzenlenemez, revize edilemez ve durumu '
                              'değiştirilemez.',
                          confirmLabel: 'Kabul Edildi',
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: SecondaryButton(
                        label: 'Reddedildi',
                        onPressed: () => _confirmAndSetStatus(
                          Offer.statusReddedildi,
                          title: 'Teklif Reddedildi',
                          message: '${offer.offerNo} reddedildi olarak işaretlensin mi? Teklif ancak yeni bir '
                              'revizyonla yeniden açılabilir.',
                          confirmLabel: 'Reddedildi',
                          danger: true,
                        ),
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
                          onPressed: () => _convert(offer),
                        ),
                  orElse: () => const SizedBox.shrink(),
                ),
              ],
              // PDF her teklifte (pasif dahil) indirilebilir -- yalnızca okuma ister.
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  SecondaryButton(
                    icon: Icons.picture_as_pdf_outlined,
                    label: 'PDF İndir',
                    loading: _downloadingPdf,
                    onPressed: () => _downloadPdf(offer),
                  ),
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
          ),
        ),
      ),
    );
  }
}

/// Web teklif detayındaki "Paylaşım" kartının karşılığı: oluşturulmuş
/// linkler, kopyala ve iptal et. Hiç link yoksa bölüm görünmez (yeni link
/// aşağıdaki "Paylaşım Linki" düğmesiyle oluşturulur).
class _ShareLinksSection extends ConsumerStatefulWidget {
  const _ShareLinksSection({required this.offerId, required this.canRevoke});
  final String offerId;
  final bool canRevoke;

  @override
  ConsumerState<_ShareLinksSection> createState() => _ShareLinksSectionState();
}

class _ShareLinksSectionState extends ConsumerState<_ShareLinksSection> {
  String? _revokingId;
  bool _showPast = false;

  String _url(ShareLink l) => '${AppConfig.apiBaseUrl}/paylas/${l.token}';

  Future<void> _revoke(ShareLink link) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Linki İptal Et'),
        content: const Text('Bu paylaşım linki iptal edilsin mi? Müşteri bu linkten teklifi artık göremez.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('İptal Et'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _revokingId = link.id);
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      await ref.read(offersRepositoryProvider).revokeShareLink(widget.offerId, link.id);
      invalidate(offerShareLinksProvider(widget.offerId));
      invalidateOfferHistory(invalidate, widget.offerId);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _revokingId = null);
    }
  }

  String _pastLabel(ShareLink l) {
    if (l.revokedAt != null) return 'İptal edildi · ${Formatters.dateTime(l.revokedAt)}';
    if (l.expiresAt != null) return 'Süresi doldu · ${Formatters.dateTime(l.expiresAt)}';
    return 'Geçersiz';
  }

  @override
  Widget build(BuildContext context) {
    final links = ref.watch(offerShareLinksProvider(widget.offerId)).valueOrNull ?? const <ShareLink>[];
    if (links.isEmpty) return const SizedBox.shrink();
    final active = links.where((l) => l.isActive).toList();
    final past = links.where((l) => !l.isActive).toList();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppSectionHeader(title: 'Paylaşım Linkleri'),
          const SizedBox(height: AppSpacing.sm),
          if (active.isEmpty)
            const AppCard(child: Text('Aktif link yok', style: AppTypography.metadata)),
          for (final l in active)
            AppCard(
              margin: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const StatusBadge(label: 'Aktif', tone: StatusTone.success),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          l.expiresAt == null ? 'Süresiz' : 'Bitiş: ${Formatters.dateTime(l.expiresAt)}',
                          style: AppTypography.metadata,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  SelectableText(_url(l), style: AppTypography.body),
                  Text('Oluşturuldu: ${Formatters.dateTime(l.createdAt)}', style: AppTypography.helper),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.copy_outlined, size: 18),
                        label: const Text('Kopyala'),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _url(l)));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link kopyalandı')));
                        },
                      ),
                      if (widget.canRevoke)
                        TextButton(
                          onPressed: _revokingId == null ? () => _revoke(l) : null,
                          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                          child: Text(_revokingId == l.id ? 'İptal ediliyor…' : 'İptal Et'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          if (past.isNotEmpty)
            TextButton(
              onPressed: () => setState(() => _showPast = !_showPast),
              child: Text(_showPast ? 'Eski linkleri gizle' : 'Eski linkler (${past.length})'),
            ),
          if (_showPast)
            for (final l in past)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Text(_pastLabel(l), style: AppTypography.metadata),
              ),
        ],
      ),
    );
  }
}

class _ConvertToProjectSheet extends ConsumerStatefulWidget {
  const _ConvertToProjectSheet({required this.offer});
  final Offer offer;

  @override
  ConsumerState<_ConvertToProjectSheet> createState() => _ConvertToProjectSheetState();
}

class _ConvertToProjectSheetState extends ConsumerState<_ConvertToProjectSheet> {
  late final TextEditingController _name;
  final _type = TextEditingController();
  final _description = TextEditingController();
  DateTime? _start;
  DateTime? _end;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Web ile aynı öneri: "Müşteri - TeklifNo".
    _name = TextEditingController(text: '${widget.offer.customerName} - ${widget.offer.offerNo}');
  }

  @override
  void dispose() {
    _name.dispose();
    _type.dispose();
    _description.dispose();
    super.dispose();
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pick({required bool start}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (start ? _start : _end) ?? _start ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => start ? _start = picked : _end = picked);
  }

  Future<void> _submit() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Proje adı boş olamaz.');
      return;
    }
    if (_start != null && _end != null && _end!.isBefore(_start!)) {
      setState(() => _error = 'Planlanan bitiş, başlangıçtan önce olamaz.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await ref.read(offersRepositoryProvider).convertToProject(
            widget.offer.id,
            name: _name.text.trim(),
            projectType: _type.text.trim(),
            startDate: _start == null ? null : _iso(_start!),
            endDate: _end == null ? null : _iso(_end!),
            description: _description.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(result);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _dateTile(String label, DateTime? value, {required bool start}) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: Text(value == null ? 'Seçilmedi' : Formatters.date(_iso(value))),
        trailing: value == null
            ? const Icon(Icons.calendar_today_outlined, size: 18, color: AppColors.textMuted)
            : IconButton(
                tooltip: '$label temizle',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => setState(() => start ? _start = null : _end = null),
              ),
        onTap: () => _pick(start: start),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.xl,
        right: AppSpacing.xl,
        top: AppSpacing.xl,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Projeye Dönüştür', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
            Text('${widget.offer.offerNo} · ${Formatters.money(widget.offer.grandTotal, currency: widget.offer.currency)}',
                style: AppTypography.metadata),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              key: const Key('convert-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: 'Proje Adı'),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _type,
              decoration: const InputDecoration(labelText: 'Proje Tipi (opsiyonel)', hintText: 'ör. Konut, Tadilat'),
            ),
            const SizedBox(height: AppSpacing.sm),
            _dateTile('Başlangıç Tarihi', _start, start: true),
            _dateTile('Planlanan Bitiş', _end, start: false),
            TextField(
              controller: _description,
              decoration: const InputDecoration(labelText: 'Açıklama (opsiyonel)'),
              maxLines: 2,
            ),
            if (_error != null) ...[const SizedBox(height: AppSpacing.md), Text(_error!, style: AppTypography.error)],
            const SizedBox(height: AppSpacing.xl),
            PrimaryButton(label: 'Projeyi Oluştur', loading: _saving, onPressed: _submit),
          ],
        ),
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.item, required this.showInternal, required this.currency});
  final OfferItem item;
  final bool showInternal;
  final String currency;

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
              MoneyText(item.lineTotal, currency: currency, style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
          Text(
            '${item.quantity.toStringAsFixed(item.quantity.truncateToDouble() == item.quantity ? 0 : 2)} ${item.unit} × ${Formatters.money(item.unitPrice, currency: currency)}'
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
                    Text('İç maliyet: ${Formatters.money(item.internalSubcontractCost!, currency: currency)}',
                        style: AppTypography.helper),
                  Text(
                    'Mod: ${item.pricingMode == OfferItem.pricingModeMarkup ? 'Markup' : item.pricingMode == OfferItem.pricingModeManual ? 'Manuel' : '-'}',
                    style: AppTypography.helper,
                  ),
                  if (item.pricingMode == OfferItem.pricingModeMarkup && item.markupPercent != null)
                    Text('Markup: %${item.markupPercent!.toStringAsFixed(2)}', style: AppTypography.helper),
                  if (item.expectedProfit != null)
                    Text('Beklenen kâr: ${Formatters.money(item.expectedProfit!, currency: currency)}',
                        style: AppTypography.helper),
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
