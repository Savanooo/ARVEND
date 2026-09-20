import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/offers_providers.dart';
import '../domain/offer.dart';

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

  Future<void> _setStatus(String status) async {
    try {
      await ref.read(offersRepositoryProvider).updateStatus(offerId, status);
      ref.invalidate(offerDetailProvider(offerId));
      ref.invalidate(offersListProvider(''));
      ref.invalidate(offerRevisionsProvider(offerId));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _reviseAndEdit() async {
    try {
      final revised = await ref.read(offersRepositoryProvider).revise(offerId);
      ref.invalidate(offerDetailProvider(offerId));
      ref.invalidate(offersListProvider(''));
      ref.invalidate(offerRevisionsProvider(offerId));
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
    try {
      final result = await ref.read(offersRepositoryProvider).convertToProject(offerId);
      ref.invalidate(offerLinkedProjectIdProvider(offerId));
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
    try {
      final link = await ref.read(offersRepositoryProvider).createShareLink(offerId);
      if (!mounted) return;
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
    if (confirmed != true) return;
    setState(() => _sendingEmail = true);
    try {
      await ref.read(offersRepositoryProvider).sendEmail(offerId);
      ref.invalidate(offerDetailProvider(offerId));
      ref.invalidate(offersListProvider(''));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('E-posta gönderildi')));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
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

    return Scaffold(
      appBar: AppBar(
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
      ),
      body: AsyncStateView<Offer>(
        value: offerAsync,
        onRetry: () async => ref.invalidate(offerDetailProvider(offerId)),
        data: (context, offer) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(offerDetailProvider(offerId));
            ref.invalidate(offerRevisionsProvider(offerId));
            ref.invalidate(offerLinkedProjectIdProvider(offerId));
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  StatusRegistry.build(offer.status, StatusRegistry.offer),
                  Text(Formatters.money(offer.grandTotal),
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                ],
              ),
              const SizedBox(height: 8),
              Text('Revizyon #${offer.revisionNo}', style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(offer.customerName, style: const TextStyle(fontWeight: FontWeight.w700)),
                      if (offer.customerPhone.isNotEmpty) Text(offer.customerPhone),
                      if (offer.customerEmail.isNotEmpty) Text(offer.customerEmail),
                      if (offer.customerAddress.isNotEmpty) Text(offer.customerAddress),
                      const Divider(height: 20),
                      _KV('Teklif Tarihi', Formatters.date(offer.offerDate)),
                      _KV('Geçerlilik', Formatters.date(offer.validUntil)),
                      if (offer.notes.isNotEmpty) _KV('Notlar', offer.notes),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Kalemler', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              ...offer.items.map((item) => _ItemCard(item: item, showInternal: canReadInternal)),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _KV('Ara Toplam', Formatters.money(offer.subtotal)),
                      _KV('KDV (%${offer.vatRate.toStringAsFixed(0)})', Formatters.money(offer.vatAmount)),
                      const Divider(),
                      _KV('Genel Toplam', Formatters.money(offer.grandTotal), bold: true),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text('Revizyon Geçmişi', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              AsyncStateView<List<OfferRevision>>(
                value: revisionsAsync,
                onRetry: () async => ref.invalidate(offerRevisionsProvider(offerId)),
                isEmpty: (r) => r.isEmpty,
                emptyBuilder: (_) => const Card(child: ListTile(dense: true, title: Text('Henüz revizyon yok'))),
                data: (context, revs) {
                  final sorted = [...revs]..sort((a, b) => b.revisionNo.compareTo(a.revisionNo));
                  return Column(
                    children: sorted.map((r) {
                      final isCurrent = r.revisionNo == offer.revisionNo;
                      return Card(
                        child: ListTile(
                          title: Text('Revizyon #${r.revisionNo}${isCurrent ? ' (güncel)' : ''}'),
                          subtitle: Text('${Formatters.dateTime(r.createdAt)} · ${Formatters.money(r.grandTotal)}'),
                          trailing: StatusRegistry.build(r.status, StatusRegistry.offer),
                          onTap: () => context.push('/teklifler/$offerId/revizyonlar/${r.id}'),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
              const SizedBox(height: 20),
              if (offer.isEditable) ...[
                FilledButton.icon(
                  onPressed: () => context.push('/teklifler/$offerId/duzenle'),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Düzenle'),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => _setStatus(Offer.statusGonderildi),
                  child: const Text('Gönderildi Olarak İşaretle'),
                ),
              ],
              if (offer.status == Offer.statusGonderildi) ...[
                FilledButton(
                  onPressed: () => _setStatus(Offer.statusKabulEdildi),
                  child: const Text('Kabul Edildi'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => _setStatus(Offer.statusReddedildi),
                  child: const Text('Reddedildi'),
                ),
              ],
              if (offer.canRevise) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Revize Et ve Düzenle'),
                  onPressed: _reviseAndEdit,
                ),
              ],
              if (!offer.isPassive) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.ios_share_outlined, size: 18),
                  label: const Text('Paylaşım Linki Oluştur'),
                  onPressed: _creatingLink ? null : _createShareLink,
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.mail_outline, size: 18),
                  label: const Text('E-posta Gönder'),
                  onPressed: _sendingEmail ? null : _sendEmail,
                ),
              ],
              if (offer.status == Offer.statusKabulEdildi && canConvert) ...[
                const SizedBox(height: 8),
                linkedProjectIdAsync.maybeWhen(
                  data: (projectId) => projectId != null
                      ? OutlinedButton.icon(
                          icon: const Icon(Icons.business_center_outlined),
                          label: const Text('Projeyi Görüntüle'),
                          onPressed: () => context.push('/projeler/$projectId'),
                        )
                      : FilledButton.icon(
                          icon: const Icon(Icons.business_center_outlined),
                          label: const Text('Projeye Dönüştür'),
                          onPressed: _converting ? null : _convert,
                        ),
                  orElse: () => const SizedBox.shrink(),
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
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(item.productName, style: const TextStyle(fontWeight: FontWeight.w600))),
                Text(Formatters.money(item.lineTotal), style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            Text(
              '${item.quantity.toStringAsFixed(item.quantity.truncateToDouble() == item.quantity ? 0 : 2)} ${item.unit} × ${Formatters.money(item.unitPrice)}'
              '${item.sectionLabel != null ? '  ·  ${item.sectionLabel}' : ''}',
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
            if (showInternal && item.hasInternalPricing) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('İç Maliyet / Müşteri Görmez',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                    if (item.internalSubcontractCost != null)
                      Text('İç maliyet: ${Formatters.money(item.internalSubcontractCost!)}',
                          style: const TextStyle(fontSize: 12.5)),
                    Text(
                      'Mod: ${item.pricingMode == OfferItem.pricingModeMarkup ? 'Markup' : item.pricingMode == OfferItem.pricingModeManual ? 'Manuel' : '-'}',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    if (item.pricingMode == OfferItem.pricingModeMarkup && item.markupPercent != null)
                      Text('Markup: %${item.markupPercent!.toStringAsFixed(2)}', style: const TextStyle(fontSize: 12.5)),
                    if (item.expectedProfit != null)
                      Text('Beklenen kâr: ${Formatters.money(item.expectedProfit!)}', style: const TextStyle(fontSize: 12.5)),
                    if (item.effectiveMarkupPercent != null)
                      Text('Efektif markup: %${item.effectiveMarkupPercent!.toStringAsFixed(2)}',
                          style: const TextStyle(fontSize: 12.5)),
                  ],
                ),
              ),
            ],
          ],
        ),
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
          Text(label, style: const TextStyle(color: Colors.grey)),
          Flexible(
            child: Text(value,
                textAlign: TextAlign.right,
                style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, fontSize: bold ? 17 : 14)),
          ),
        ],
      ),
    );
  }
}
