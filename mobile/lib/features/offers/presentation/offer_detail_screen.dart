import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/offers_providers.dart';
import '../domain/offer.dart';

class OfferDetailScreen extends ConsumerWidget {
  const OfferDetailScreen({super.key, required this.offerId});
  final String offerId;

  Future<void> _changeStatus(BuildContext context, WidgetRef ref, String status) async {
    try {
      await ref.read(offersRepositoryProvider).updateStatus(offerId, status);
      ref.invalidate(offerDetailProvider(offerId));
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offerAsync = ref.watch(offerDetailProvider(offerId));

    return Scaffold(
      appBar: AppBar(
        title: offerAsync.maybeWhen(data: (o) => Text(o.offerNo), orElse: () => const Text('Teklif')),
      ),
      body: AsyncStateView(
        value: offerAsync,
        onRetry: () async => ref.invalidate(offerDetailProvider(offerId)),
        data: (context, offer) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(offerDetailProvider(offerId)),
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
                      const Divider(height: 20),
                      _Row('Teklif Tarihi', Formatters.date(offer.offerDate)),
                      _Row('Geçerlilik', Formatters.date(offer.validUntil)),
                      _Row('Revizyon', '${offer.revisionNo}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Kalemler', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              ...offer.items.map((item) => _OfferItemTile(item: item)),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _Row('Ara Toplam', Formatters.money(offer.subtotal)),
                      _Row('KDV (%${offer.vatRate.toStringAsFixed(0)})', Formatters.money(offer.vatAmount)),
                      const Divider(),
                      _Row('Genel Toplam', Formatters.money(offer.grandTotal), emphasize: true),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _ActionsSection(offer: offer, onStatusChange: (s) => _changeStatus(context, ref, s)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionsSection extends ConsumerWidget {
  const _ActionsSection({required this.offer, required this.onStatusChange});
  final Offer offer;
  final void Function(String status) onStatusChange;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = <Widget>[];

    if (offer.status == 'taslak') {
      actions.add(FilledButton(
        onPressed: () => onStatusChange('gönderildi'),
        child: const Text('Gönderildi Olarak İşaretle'),
      ));
    }
    if (offer.status == 'gönderildi') {
      actions.addAll([
        FilledButton(onPressed: () => onStatusChange('kabul edildi'), child: const Text('Kabul Edildi')),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: () => onStatusChange('reddedildi'), child: const Text('Reddedildi')),
      ]);
    }
    if (offer.status == 'gönderildi' || offer.status == 'reddedildi') {
      actions.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: OutlinedButton.icon(
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Revize Et'),
          onPressed: () async {
            try {
              final revised = await ref.read(offersRepositoryProvider).revise(offer.id);
              ref.invalidate(offerDetailProvider(offer.id));
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('Yeni revizyon oluşturuldu (${revised.revisionNo})')));
              }
            } on ApiException catch (e) {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
            }
          },
        ),
      ));
    }
    if (offer.status == 'kabul edildi') {
      actions.add(FilledButton.icon(
        icon: const Icon(Icons.business_center_outlined),
        label: const Text('Projeye Dönüştür'),
        onPressed: () async {
          try {
            await ref.read(offersRepositoryProvider).convertToProject(offer.id);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Proje oluşturuldu')));
              context.go('/projeler');
            }
          } on ApiException catch (e) {
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
          }
        },
      ));
    }

    if (actions.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: actions);
  }
}

class _OfferItemTile extends StatelessWidget {
  const _OfferItemTile({required this.item});
  final OfferItem item;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        title: Text(item.productName, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${item.quantity.toStringAsFixed(item.quantity.truncateToDouble() == item.quantity ? 0 : 2)} ${item.unit} × ${Formatters.money(item.unitPrice)}'
          '${item.sectionLabel != null ? '  ·  ${item.sectionLabel}' : ''}',
        ),
        trailing: Text(Formatters.money(item.lineTotal), style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.emphasize = false});
  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value,
              style: TextStyle(fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600, fontSize: emphasize ? 17 : 14)),
        ],
      ),
    );
  }
}
