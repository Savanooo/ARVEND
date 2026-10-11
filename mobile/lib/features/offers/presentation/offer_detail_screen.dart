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
import '../../../core/widgets/access_notices.dart';
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

/// Taslak teklifte "Paylaşım Linki" sorusunun cevabı (bkz.
/// `_askDraftShareChoice`); null = Vazgeç.
enum _DraftShareChoice { send, preview }

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
      // "Gönderildi"ye geçiş önceki revizyonların linklerini sunucuda iptal
      // eder: "Paylaşım Linkleri" onları hâlâ "Aktif" göstermesin.
      invalidate(offerShareLinksProvider(offerId));
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
    final result = await showAppSheet<_ConvertResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ConvertToProjectSheet(offer: offer),
    );
    if (result == null) return;
    invalidate(offerProjectLinkProvider(offerId));
    invalidateOfferHistory(invalidate, offerId);
    if (!mounted) return;
    final message = result.alreadyConvertedMessage;
    if (message != null) {
      // Teklif bu arada (başka biri tarafından) erişimin olmayan bir projeye
      // dönüştürülmüş: proje açılmadı, düğmeler tazelenen bilgiye göre değişir.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    final projectId = result.project?['id'] as String?;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Proje oluşturuldu')));
    if (projectId != null) {
      context.go('/projeler/$projectId');
    } else {
      context.go('/projeler');
    }
  }

  /// Taslak teklifin linkinde müşteri teklifi görür ama Kabul Et / Reddet
  /// göremez (yalnızca "gönderildi" bir revizyon yanıtlanabilir). Sahada
  /// link WhatsApp'tan atılıyor, "Gönderildi Olarak İşaretle" unutuluyordu
  /// ("teklif atıyoruz, link vb., teklif kabul etme yok") -- bu yüzden
  /// taslakta link oluşturmadan önce sorulur. Önizleme linki bilerek
  /// seçenek olarak kalır (müşteriye göndermeden kontrol etmek için).
  /// Durum değiştirme yetkisi (offers.approve) olmayana yalnızca önizleme
  /// sunulur; sunucu da mark_sent'i bu izin olmadan reddeder.
  /// [expired]: geçerlilik tarihi geçmiş taslak gönderilemez (sunucu 409);
  /// yalnızca önizleme linki sunulur ve nedeni söylenir.
  Future<_DraftShareChoice?> _askDraftShareChoice({required bool canMarkSent, bool expired = false}) {
    final canSend = canMarkSent && !expired;
    return showDialog<_DraftShareChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Teklif taslak'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              canSend
                  ? "Müşterinin linkten Kabul Et / Reddet yapabilmesi için teklif 'Gönderildi' olmalı. "
                      'Gönderildi olarak işaretleyip linki oluşturayım mı?'
                  : "Müşterinin linkten Kabul Et / Reddet yapabilmesi için teklif 'Gönderildi' olmalı.",
            ),
            if (expired) ...[
              const SizedBox(height: AppSpacing.sm),
              const Text(
                'Geçerlilik tarihi geçtiği için teklif gönderilemez; oluşturulacak link yalnızca önizlemedir. '
                'Göndermek için önce teklifi düzenleyip tarihi güncelle.',
                key: ValueKey('share-draft-expired-note'),
                style: AppTypography.metadata,
              ),
            ] else if (!canMarkSent) ...[
              const SizedBox(height: AppSpacing.sm),
              const Text(
                'Teklif durumunu değiştirme yetkiniz yok; oluşturulacak link yalnızca önizlemedir.',
                key: ValueKey('share-draft-no-permission-note'),
                style: AppTypography.metadata,
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Vazgeç')),
          TextButton(
            key: const ValueKey('share-draft-preview'),
            onPressed: () => Navigator.of(context).pop(_DraftShareChoice.preview),
            child: const Text('Yalnızca önizleme linki'),
          ),
          if (canSend)
            FilledButton(
              key: const ValueKey('share-draft-send'),
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(_DraftShareChoice.send),
              child: const Text('Gönder ve link oluştur'),
            ),
        ],
      ),
    );
  }

  Future<void> _createShareLink(Offer offer, {required bool canMarkSent, bool expired = false}) async {
    var markSent = false;
    if (offer.status == Offer.statusTaslak) {
      final choice = await _askDraftShareChoice(canMarkSent: canMarkSent, expired: expired);
      if (choice == null || !mounted) return;
      markSent = choice == _DraftShareChoice.send;
    }
    setState(() => _creatingLink = true);
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      final link = await ref.read(offersRepositoryProvider).createShareLink(offerId, markSent: markSent);
      // Link oluşturma bir olay (share_link_created) üretir.
      invalidateOfferHistory(invalidate, offerId);
      invalidate(offerShareLinksProvider(offerId));
      if (markSent) {
        // Durum çipi, revizyon listesi ve teklif listesi "Gönderildi"yi
        // göstersin; önceki revizyonların linkleri de sunucuda iptal edildi.
        invalidate(offerDetailProvider(offerId));
        invalidate(offersListProvider(''));
        invalidate(offerRevisionsProvider(offerId));
      }
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

  /// Geçerlilik tarihi geçmiş teklif müşteriye gönderilemez (sunucu 409:
  /// "göndermeden önce geçerlilik tarihini güncelleyin"). Gönderim düğmesine
  /// basana nedenini ve ne yapacağını söyler; taslakta düzenlemeye götürür.
  Future<void> _explainExpired(Offer offer, {required bool canUpdate}) async {
    final canFix = offer.isEditable && canUpdate;
    final edit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('offer-expired-dialog'),
        title: const Text('Geçerlilik tarihi geçmiş'),
        content: Text(_expiredText(offer, canUpdate: canUpdate)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(canFix ? 'Vazgeç' : 'Tamam')),
          if (canFix)
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Tarihi Güncelle')),
        ],
      ),
    );
    if (edit == true && mounted) context.push('/teklifler/$offerId/duzenle');
  }

  /// Arşive alma / arşivden çıkarma (offers.approve). Arşivdeki teklif
  /// "Pasif" listesine düşer, düzenlenemez, gönderilemez ve müşteri paylaşım
  /// linkinden açamaz; arşivden çıkınca linkler yeniden çalışır. Eskiden bu
  /// uç hiçbir arayüze bağlı değildi: vazgeçilen teklifi geri çekmenin tek
  /// yolu silmekti (geçmişiyle birlikte).
  Future<void> _setPassive(Offer offer, {required bool passive}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(passive ? 'Teklifi Arşivle' : 'Arşivden Çıkar'),
        content: Text(
          passive
              ? '${offer.offerNo} arşive alınsın mı? Teklif "Pasif" listesine taşınır; düzenlenemez, '
                  'gönderilemez ve müşteri paylaşım linkinden açamaz. İstediğin zaman arşivden çıkarabilirsin.'
              : '${offer.offerNo} arşivden çıkarılsın mı? Teklif yeniden aktif listede görünür; iptal '
                  'edilmemiş paylaşım linkleri yeniden açılır.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          TextButton(
            key: const ValueKey('offer-passive-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(passive ? 'Arşivle' : 'Arşivden Çıkar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      await ref.read(offersRepositoryProvider).setPassive(offerId, passive: passive);
      invalidate(offerDetailProvider(offerId));
      invalidate(offersListProvider(''));
      invalidate(offersListProvider('pasif'));
      invalidateOfferHistory(invalidate, offerId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(passive ? '${offer.offerNo} arşivlendi' : '${offer.offerNo} arşivden çıkarıldı')),
      );
    } on ApiException catch (e) {
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
      // Taslak gönderilince durum "gönderildi" olur ve önceki revizyonların
      // linkleri iptal edilir: durum çipi, liste ve revizyon listesi tazelenir.
      invalidate(offerDetailProvider(offerId));
      invalidate(offersListProvider(''));
      invalidate(offerRevisionsProvider(offerId));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('E-posta gönderildi')));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      // Başarısız gönderim de "Mail Geçmişi"ne (failed) düşer -- her iki
      // durumda da geçmiş tazelenir. Mailin taşıdığı paylaşım linki de
      // gönderimden ÖNCE oluşturulur: "Paylaşım Linkleri" iki durumda da
      // tazelenir.
      invalidateOfferHistory(invalidate, offerId);
      invalidate(offerShareLinksProvider(offerId));
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
    final canApprove = user?.hasPermission(kPermOffersApprove) ?? false;
    final canDelete = user?.hasPermission(kPermOffersDelete) ?? false;
    // Geçerlilik tarihi geçmiş (arşivde olmayan) teklif müşteriye gönderilemez.
    final today = ref.watch(offersTodayProvider);
    final loaded = offerAsync.valueOrNull;
    final expired = loaded != null && !loaded.isPassive && loaded.validityExpiredOn(today);
    // Yalnızca kabul edilmiş teklif dönüştürülebilir; /offers/{id}/project
    // de projects.read ister. Bu ikisi yoksa sorgu hiç atılmaz. projects.read
    // olmadan proje açabilen (özel rol) için karar sunucudadır: dönüştürülmüş
    // teklifte "Projeye Dönüştür" 409 ile nedenini söyler.
    final canReadProjects = user?.hasPermission(kPermProjectsRead) ?? false;
    final accepted = offerAsync.valueOrNull?.status == Offer.statusKabulEdildi;
    final projectLinkAsync = accepted && canReadProjects
        ? ref.watch(offerProjectLinkProvider(offerId))
        : const AsyncValue<OfferProjectLink>.data(OfferProjectLink.none);

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
        // Düzenleme ucu (PUT /offers/{id}) offers.update ister: izni olmayan
        // formu doldurup kaydederken 403 alıyordu.
        offerAsync.maybeWhen(
          data: (o) => o.isEditable && canUpdate
              ? IconButton(
                  tooltip: 'Düzenle',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => context.push('/teklifler/$offerId/duzenle'),
                )
              : const SizedBox.shrink(),
          orElse: () => const SizedBox.shrink(),
        ),
        offerAsync.maybeWhen(
          data: (o) {
            // Kabul edilmiş teklif silinemez (backend ErrOfferAccepted) --
            // seçenek hiç sunulmaz; web'deki "Sil" düğmesinin karşılığı.
            final showDelete = canDelete && o.status != Offer.statusKabulEdildi;
            // Arşivleme (toggle-passive) durum değiştirmektir: offers.approve.
            final showArchive = canApprove;
            if (!showDelete && !showArchive) return const SizedBox.shrink();
            return PopupMenuButton<String>(
              tooltip: 'Diğer işlemler',
              onSelected: (v) {
                if (v == 'arsiv') _setPassive(o, passive: !o.isPassive);
                if (v == 'sil') _delete(o);
              },
              itemBuilder: (_) => [
                if (showArchive)
                  PopupMenuItem(
                    value: 'arsiv',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(o.isPassive ? Icons.unarchive_outlined : Icons.archive_outlined),
                      title: Text(o.isPassive ? 'Arşivden Çıkar' : 'Arşivle'),
                    ),
                  ),
                if (showDelete)
                  const PopupMenuItem(
                    value: 'sil',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline, color: AppColors.danger),
                      title: Text('Teklifi Sil', style: TextStyle(color: AppColors.danger)),
                    ),
                  ),
              ],
            );
          },
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
            ref.invalidate(offerProjectLinkProvider(offerId));
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
              if (offer.isPassive) ...[
                const SizedBox(height: AppSpacing.md),
                ReadOnlyNotice(
                  'Bu teklif arşivde (Pasif): düzenlenemez, gönderilemez ve müşteri paylaşım linkinden açamaz.'
                  '${canApprove ? ' Geri almak için sağ üstteki menüden "Arşivden Çıkar"ı kullan.' : ''}',
                  key: const ValueKey('offer-passive-notice'),
                ),
              ],
              if (expired && (offer.status == Offer.statusTaslak || offer.status == Offer.statusGonderildi)) ...[
                const SizedBox(height: AppSpacing.md),
                _ExpiredValidityNotice(
                  text: _expiredText(offer, canUpdate: canUpdate),
                  onFix: offer.isEditable && canUpdate ? () => context.push('/teklifler/$offerId/duzenle') : null,
                ),
              ],
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
              // Durum ucu (PUT /offers/{id}/status) offers.approve ister: izni
              // olmayana düğme gösterilip 403 snackbar'ıyla geri çevrilmez.
              // Paylaşım linki sorusu da aynı `canApprove` ile karar verir.
              if (offer.isEditable && canApprove)
                PrimaryButton(
                  label: 'Gönderildi Olarak İşaretle',
                  // Süresi geçmiş taslak gönderilemez: onay yerine nedeni.
                  onPressed: expired
                      ? () => _explainExpired(offer, canUpdate: canUpdate)
                      : () => _confirmAndSetStatus(
                            Offer.statusGonderildi,
                            title: 'Gönderildi Olarak İşaretle',
                            message: '${offer.offerNo} gönderildi olarak işaretlensin mi? Bu revizyon artık '
                                'düzenlenemez; değişiklik için yeni bir revizyon gerekir.',
                            confirmLabel: 'İşaretle',
                          ),
                ),
              if (offer.status == Offer.statusGonderildi && canApprove)
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
              if (offer.status == Offer.statusKabulEdildi && (canConvert || canReadProjects)) ...[
                const SizedBox(height: AppSpacing.sm),
                projectLinkAsync.when(
                  data: (link) {
                    final projectId = link.projectId;
                    if (projectId != null) {
                      return SecondaryButton(
                        icon: Icons.business_center_outlined,
                        label: 'Projeyi Görüntüle',
                        onPressed: () => context.push('/projeler/$projectId'),
                      );
                    }
                    if (link.noAccess) {
                      return const ReadOnlyNotice(
                        'Bu teklif bir projeye dönüştürülmüş; o projenin üyesi olmadığın için projeyi göremezsin.',
                        key: ValueKey('offer-project-no-access'),
                      );
                    }
                    if (!canConvert) return const SizedBox.shrink();
                    return PrimaryButton(
                      icon: Icons.business_center_outlined,
                      label: 'Projeye Dönüştür',
                      onPressed: () => _convert(offer),
                    );
                  },
                  loading: () => const SizedBox.shrink(),
                  // Eskiden her hata "dönüştürülmemiş" sayılıp "Projeye
                  // Dönüştür" gösteriliyordu; tahmin yerine hata + tekrar dene.
                  error: (_, _) => Row(
                    key: const ValueKey('offer-project-link-error'),
                    children: [
                      const Expanded(
                        child: Text(
                          'Teklifin projeye dönüştürülüp dönüştürülmediği okunamadı.',
                          style: AppTypography.metadata,
                        ),
                      ),
                      TextButton(
                        onPressed: () => ref.invalidate(offerProjectLinkProvider(offerId)),
                        child: const Text('Tekrar Dene'),
                      ),
                    ],
                  ),
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
                  // Revize, paylaşım linki ve e-posta uçları offers.update ister
                  // (router.go): izni olmayana düğme gösterilip 403 ile
                  // geri çevrilmez.
                  if (offer.canRevise && canUpdate)
                    SecondaryButton(icon: Icons.refresh, label: 'Revize Et ve Düzenle', onPressed: _reviseAndEdit),
                  if (!offer.isPassive && canUpdate) ...[
                    SecondaryButton(
                      icon: Icons.ios_share_outlined,
                      label: 'Paylaşım Linki',
                      loading: _creatingLink,
                      onPressed: () => _createShareLink(offer, canMarkSent: canApprove, expired: expired),
                    ),
                    SecondaryButton(
                      icon: Icons.mail_outline,
                      label: 'E-posta Gönder',
                      loading: _sendingEmail,
                      onPressed: expired ? () => _explainExpired(offer, canUpdate: canUpdate) : _sendEmail,
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

/// Süresi geçmiş teklifte ne olduğunu ve ne yapılacağını söyleyen metin
/// (detaydaki uyarı ve gönderim düğmelerinin açıklaması).
String _expiredText(Offer offer, {required bool canUpdate}) {
  final date = Formatters.date(offer.validUntil);
  switch (offer.status) {
    case Offer.statusTaslak:
      final next = canUpdate
          ? 'Teklifi düzenleyip yeni bir tarih seç ya da süresiz yap.'
          : 'Tarihi, teklif düzenleme yetkisi olan biri güncelleyebilir.';
      return 'Geçerlilik tarihi geçti ($date); bu haliyle müşteriye gönderilemez. $next';
    case Offer.statusKabulEdildi:
      return 'Geçerlilik tarihi geçti ($date); teklif e-postayla yeniden gönderilemez.';
    default:
      final next = offer.canRevise && canUpdate
          ? ' Yeni fiyat ve süreyle göndermek için "Revize Et ve Düzenle"yi kullan.'
          : '';
      return 'Geçerlilik tarihi geçti ($date); müşteri bu teklifi artık linkten kabul edemez ve teklif '
          'yeniden gönderilemez.$next';
  }
}

/// Detayın üstündeki "geçerlilik tarihi geçti" uyarısı; taslakta (izin
/// varsa) doğrudan düzenlemeye götüren "Tarihi Güncelle" düğmesiyle.
class _ExpiredValidityNotice extends StatelessWidget {
  const _ExpiredValidityNotice({required this.text, this.onFix});

  final String text;
  final VoidCallback? onFix;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('offer-expired-notice'),
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, 10, AppSpacing.md, 10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.warning),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(text, style: AppTypography.helper.copyWith(color: AppColors.textPrimary, height: 1.35)),
              ),
            ],
          ),
          if (onFix != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.event_outlined, size: 18),
                label: const Text('Tarihi Güncelle'),
                onPressed: onFix,
              ),
            ),
        ],
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

/// Projeye dönüştürme formunun sonucu: açılan (ya da teklif zaten
/// dönüştürülmüşse görme yetkisi olan kişiye dönen mevcut) proje, veya teklif
/// erişimin olmayan bir projeye dönüştürülmüşse sunucunun açıklaması.
class _ConvertResult {
  const _ConvertResult.project(Map<String, dynamic> this.project) : alreadyConvertedMessage = null;
  const _ConvertResult.alreadyConverted(String this.alreadyConvertedMessage) : project = null;

  final Map<String, dynamic>? project;
  final String? alreadyConvertedMessage;
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
      if (mounted) Navigator.of(context).pop(_ConvertResult.project(result));
    } on ApiException catch (e) {
      if (e.code == 'offer_already_converted') {
        // Form açıkken teklif erişimin olmayan bir projeye dönüştürüldü:
        // formda bekletmek yerine kapatılır, detay tazelenir.
        if (mounted) Navigator.of(context).pop(_ConvertResult.alreadyConverted(e.message));
        return;
      }
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
