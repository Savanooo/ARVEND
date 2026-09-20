import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/projects_providers.dart';
import '../domain/procurement.dart';

/// P3 — Teklif Karşılaştırma. Backend "en düşük"/"kazanan" alanı DÖNMEZ
/// (bkz. domain/procurement.dart `BidComparisonCell` yorumu) -- bu ekran
/// yalnızca ham karşılaştırma verisini gösterir, kendi rozetini/önerisini
/// İCAT ETMEZ. `quotations` listesi backend'den ZATEN toplam-artan sırayla
/// gelir (SQL `ORDER BY total ASC`) -- mobil bu sırayı OLDUĞU GİBİ korur,
/// kendi sıralamasını uygulamaz.
class BidComparisonScreen extends ConsumerWidget {
  const BidComparisonScreen({super.key, required this.projectId, required this.rfqId});
  final String projectId;
  final String rfqId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, rfqId: rfqId);
    final comparisonAsync = ref.watch(bidComparisonProvider(args));

    return Scaffold(
      appBar: AppBar(title: const Text('Teklif Karşılaştırma')),
      body: AsyncStateView(
        value: comparisonAsync,
        onRetry: () async => ref.invalidate(bidComparisonProvider(args)),
        data: (context, comparison) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(bidComparisonProvider(args)),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('Teklif Toplamları', style: TextStyle(fontWeight: FontWeight.w700)),
              const Padding(
                padding: EdgeInsets.only(top: 2, bottom: 8),
                child: Text(
                  'Sıralama backend\'den geldiği gibi gösterilir. Karar, RFQ ekranındaki "Ödüllendir" aksiyonuyla verilir.',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey),
                ),
              ),
              ...comparison.quotations.map((q) => Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      title: Text(q.supplierName ?? q.supplierId, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [
                          if (q.deliveryDays != null) '${q.deliveryDays} gün teslimat',
                          if (q.paymentTerms.isNotEmpty) q.paymentTerms,
                        ].join(' · '),
                      ),
                      trailing: Text(Formatters.money(q.total, currency: q.currency),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  )),
              const SizedBox(height: 20),
              const Text('Kalem Bazlı Karşılaştırma', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              if (comparison.rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('Karşılaştırılacak kalem yok.', style: TextStyle(color: Colors.grey)),
                )
              else
                ...comparison.rows.map((row) => _ComparisonRowCard(row: row, quotations: comparison.quotations)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ComparisonRowCard extends StatelessWidget {
  const _ComparisonRowCard({required this.row, required this.quotations});
  final BidComparisonRow row;
  final List<Quotation> quotations;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(row.item.description, style: const TextStyle(fontWeight: FontWeight.w700)),
            Text('${row.item.quantity} ${row.item.unit}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            const Divider(height: 16),
            if (row.cells.isEmpty)
              const Text('Bu kalem için teklif yok.', style: TextStyle(color: Colors.grey))
            else
              ...quotations.where((q) => row.cells.containsKey(q.supplierId)).map((q) {
                final cell = row.cells[q.supplierId]!;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(q.supplierName ?? q.supplierId, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      Text('${Formatters.money(cell.unitPrice, currency: q.currency)} / birim',
                          style: const TextStyle(color: Colors.grey, fontSize: 12.5)),
                      const SizedBox(width: 8),
                      Text(Formatters.money(cell.lineTotal, currency: q.currency),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
