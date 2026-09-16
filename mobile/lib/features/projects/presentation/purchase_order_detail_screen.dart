import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/projects_providers.dart';
import '../domain/procurement.dart';

/// Sprint 4 — Satın Alma Siparişi detayı, mobilde YALNIZCA OKUMA (bkz.
/// domain/procurement.dart dosya başı notu). Onay/iptal/kapatma
/// aksiyonları YOKTUR -- yalnızca görüntüleme. `commitments` (maliyet
/// kontrolü bağlantısı) backend'den gelir ama bilinçli olarak
/// gösterilmez (web-first kapsam).
class PurchaseOrderDetailScreen extends ConsumerWidget {
  const PurchaseOrderDetailScreen({super.key, required this.projectId, required this.poId});
  final String projectId;
  final String poId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, poId: poId);
    final detailAsync = ref.watch(purchaseOrderDetailProvider(args));

    return Scaffold(
      appBar: AppBar(
        title: detailAsync.maybeWhen(
          data: (d) => Text(d.order.poNo),
          orElse: () => const Text('Satın Alma Siparişi'),
        ),
      ),
      body: AsyncStateView(
        value: detailAsync,
        onRetry: () async => ref.invalidate(purchaseOrderDetailProvider(args)),
        data: (context, detail) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(purchaseOrderDetailProvider(args)),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  StatusRegistry.build(detail.order.status, StatusRegistry.purchaseOrder),
                  Text(Formatters.money(detail.order.total, currency: detail.order.currency),
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
                      Text(detail.order.supplierName ?? detail.order.supplierCode ?? '-',
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      const Divider(height: 20),
                      _Row('Sipariş Tarihi', Formatters.date(detail.order.issueDate)),
                      _Row('Beklenen Teslimat', Formatters.date(detail.order.expectedDeliveryDate)),
                      if (detail.order.paymentTerms.isNotEmpty)
                        _Row('Ödeme Koşulları', detail.order.paymentTerms),
                      if (detail.order.deliveryAddress.isNotEmpty)
                        _Row('Teslimat Adresi', detail.order.deliveryAddress),
                      if (detail.order.approvedAt != null)
                        _Row('Onaylanma', Formatters.dateTime(detail.order.approvedAt)),
                      if (detail.order.cancelledAt != null)
                        _Row('İptal', Formatters.dateTime(detail.order.cancelledAt)),
                      if (detail.order.closedAt != null)
                        _Row('Kapatılma', Formatters.dateTime(detail.order.closedAt)),
                    ],
                  ),
                ),
              ),
              if (detail.order.cancelReason.isNotEmpty) ...[
                const SizedBox(height: 12),
                _ReasonCard(label: 'İptal Gerekçesi', reason: detail.order.cancelReason),
              ],
              if (detail.order.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                _ReasonCard(label: 'Notlar', reason: detail.order.notes),
              ],
              const SizedBox(height: 16),
              const Text('Kalemler', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              if (detail.items.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('Kalem yok.', style: TextStyle(color: Colors.grey)),
                )
              else
                ...detail.items.map((item) => _PurchaseOrderItemTile(item: item, currency: detail.order.currency)),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _Row('Ara Toplam', Formatters.money(detail.order.subtotal, currency: detail.order.currency)),
                      _Row('KDV (%${detail.order.taxRate.toStringAsFixed(0)})',
                          Formatters.money(detail.order.tax, currency: detail.order.currency)),
                      const Divider(),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Genel Toplam', style: TextStyle(color: Colors.grey)),
                            Text(Formatters.money(detail.order.total, currency: detail.order.currency),
                                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PurchaseOrderItemTile extends StatelessWidget {
  const _PurchaseOrderItemTile({required this.item, required this.currency});
  final PurchaseOrderItem item;
  final String currency;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        title: Text(item.description, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${item.quantity.toStringAsFixed(item.quantity.truncateToDouble() == item.quantity ? 0 : 2)} ${item.unit}'
          '  ×  ${Formatters.money(item.unitPrice, currency: currency)}',
        ),
        trailing: Text(Formatters.money(item.lineTotal, currency: currency),
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class _ReasonCard extends StatelessWidget {
  const _ReasonCard({required this.label, required this.reason});
  final String label;
  final String reason;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.grey)),
            const SizedBox(height: 4),
            Text(reason),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
