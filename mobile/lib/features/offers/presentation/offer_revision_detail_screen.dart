import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/offers_providers.dart';
import '../domain/offer.dart';

class OfferRevisionDetailScreen extends ConsumerWidget {
  const OfferRevisionDetailScreen({super.key, required this.offerId, required this.revisionId});
  final String offerId;
  final String revisionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (offerId: offerId, revisionId: revisionId);
    final async = ref.watch(offerRevisionDetailProvider(key));
    final currentNo = ref.watch(offerDetailProvider(offerId)).valueOrNull?.revisionNo;
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canReadInternal = user?.hasPermission(kPermOffersInternalPricingRead) ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('Revizyon Detayı')),
      body: AsyncStateView<OfferRevision>(
        value: async,
        onRetry: () async => ref.invalidate(offerRevisionDetailProvider(key)),
        data: (context, rev) {
          final isCurrent = currentNo != null && rev.revisionNo == currentNo;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  StatusRegistry.build(rev.status, StatusRegistry.offer),
                  if (isCurrent) ...[
                    const SizedBox(width: 8),
                    const Chip(label: Text('Güncel'), visualDensity: VisualDensity.compact),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text('Revizyon #${rev.revisionNo}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              Text(Formatters.dateTime(rev.createdAt), style: const TextStyle(color: Colors.black54)),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(rev.customerName, style: const TextStyle(fontWeight: FontWeight.w700)),
                      if (rev.customerPhone.isNotEmpty) Text(rev.customerPhone),
                      if (rev.notes.isNotEmpty) ...[const Divider(height: 20), Text(rev.notes)],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Kalemler', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              if (rev.items.isEmpty)
                const Card(child: ListTile(dense: true, title: Text('Kalem yok')))
              else
                ...rev.items.map((item) => Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        title: Text(item.productName),
                        subtitle: Text(
                          '${item.quantity} ${item.unit} × ${Formatters.money(item.unitPrice, currency: rev.currency)}'
                          '${canReadInternal && item.hasInternalPricing && item.internalSubcontractCost != null ? '\nİç maliyet: ${Formatters.money(item.internalSubcontractCost!, currency: rev.currency)}' : ''}',
                        ),
                        isThreeLine: canReadInternal && item.hasInternalPricing,
                        trailing: Text(Formatters.money(item.lineTotal, currency: rev.currency),
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    )),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _row('Ara Toplam', Formatters.money(rev.subtotal, currency: rev.currency)),
                      _row('KDV (%${rev.vatRate.toStringAsFixed(0)})',
                          Formatters.money(rev.vatAmount, currency: rev.currency)),
                      const Divider(),
                      _row('Genel Toplam', Formatters.money(rev.grandTotal, currency: rev.currency), bold: true),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Geçmiş revizyonlar değiştirilemez.',
                  style: TextStyle(color: Colors.black54, fontSize: 12.5)),
            ],
          );
        },
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Colors.grey)),
            Text(value, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, fontSize: bold ? 17 : 14)),
          ],
        ),
      );
}
