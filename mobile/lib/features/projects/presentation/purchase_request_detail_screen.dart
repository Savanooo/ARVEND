import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/projects_providers.dart';
import '../domain/procurement.dart';

/// Sprint 4 — Satın Alma Talebi detayı, mobilde YALNIZCA OKUMA (bkz.
/// domain/procurement.dart dosya başı notu). Onay/red/iptal/düzenleme
/// aksiyonları YOKTUR -- yalnızca görüntüleme.
class PurchaseRequestDetailScreen extends ConsumerWidget {
  const PurchaseRequestDetailScreen({super.key, required this.projectId, required this.prId});
  final String projectId;
  final String prId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, prId: prId);
    final detailAsync = ref.watch(purchaseRequestDetailProvider(args));

    return Scaffold(
      appBar: AppBar(
        title: detailAsync.maybeWhen(
          data: (d) => Text(d.request.prNo),
          orElse: () => const Text('Satın Alma Talebi'),
        ),
      ),
      body: AsyncStateView(
        value: detailAsync,
        onRetry: () async => ref.invalidate(purchaseRequestDetailProvider(args)),
        data: (context, detail) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(purchaseRequestDetailProvider(args)),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  StatusRegistry.build(detail.request.status, StatusRegistry.purchaseRequest),
                  Text(Formatters.money(detail.request.estimatedTotal),
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
                      Text(detail.request.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                      if (detail.request.description.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(detail.request.description),
                      ],
                      const Divider(height: 20),
                      _Row('İhtiyaç Tarihi', Formatters.date(detail.request.neededBy)),
                      _Row('Oluşturulma', Formatters.dateTime(detail.request.createdAt)),
                      if (detail.request.submittedAt != null)
                        _Row('Gönderilme', Formatters.dateTime(detail.request.submittedAt)),
                      if (detail.request.approvedAt != null)
                        _Row('Onaylanma', Formatters.dateTime(detail.request.approvedAt)),
                      if (detail.request.rejectedAt != null)
                        _Row('Reddedilme', Formatters.dateTime(detail.request.rejectedAt)),
                      if (detail.request.cancelledAt != null)
                        _Row('İptal', Formatters.dateTime(detail.request.cancelledAt)),
                    ],
                  ),
                ),
              ),
              if (detail.request.rejectionReason.isNotEmpty) ...[
                const SizedBox(height: 12),
                _ReasonCard(label: 'Red Gerekçesi', reason: detail.request.rejectionReason),
              ],
              if (detail.request.cancelReason.isNotEmpty) ...[
                const SizedBox(height: 12),
                _ReasonCard(label: 'İptal Gerekçesi', reason: detail.request.cancelReason),
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
                ...detail.items.map((item) => _PurchaseRequestItemTile(item: item)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PurchaseRequestItemTile extends StatelessWidget {
  const _PurchaseRequestItemTile({required this.item});
  final PurchaseRequestItem item;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        title: Text(item.description, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${item.quantity.toStringAsFixed(item.quantity.truncateToDouble() == item.quantity ? 0 : 2)} ${item.unit}'
          '${item.estimatedUnitCost != null ? '  ×  ${Formatters.money(item.estimatedUnitCost!)}' : ''}',
        ),
        trailing: Text(Formatters.money(item.estimatedTotal), style: const TextStyle(fontWeight: FontWeight.w700)),
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
