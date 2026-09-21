import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_comparison_table.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/money_text.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/projects_providers.dart';

/// P3 — Teklif Karşılaştırma. Backend "en düşük"/"kazanan" alanı DÖNMEZ
/// (bkz. domain/procurement.dart `BidComparisonCell` yorumu) -- bu ekran
/// yalnızca ham karşılaştırma verisini yan yana gösterir, kendi rozetini/
/// önerisini İCAT ETMEZ. Hangi teklifin ödüllendirildiği YALNIZCA
/// `rfq.awardedQuotationId` ile işaretlenir (zaten RFQ detayında çekilmiş
/// olan `rfqDetailProvider`den -- ikinci bir ağ isteği İCAT EDİLMEZ, RFQ
/// detay ekranı navigasyon yığınında hâlâ canlıyken bu sağlanır).
/// `quotations` listesi backend'den ZATEN toplam-artan sırayla gelir (SQL
/// `ORDER BY total ASC`) -- mobil bu sırayı OLDUĞU GİBİ korur.
class BidComparisonScreen extends ConsumerWidget {
  const BidComparisonScreen({super.key, required this.projectId, required this.rfqId});
  final String projectId;
  final String rfqId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, rfqId: rfqId);
    final comparisonAsync = ref.watch(bidComparisonProvider(args));
    final rfqAsync = ref.watch(rfqDetailProvider(args));
    final awardedQuotationId = rfqAsync.valueOrNull?.rfq.awardedQuotationId;

    return AppPageScaffold(
      title: const Text('Teklif Karşılaştırma'),
      body: AsyncStateView(
        value: comparisonAsync,
        onRetry: () async => ref.invalidate(bidComparisonProvider(args)),
        isEmpty: (c) => c.quotations.isEmpty,
        emptyBuilder: (_) => const EmptyStateView(message: 'Karşılaştırılacak teklif yok.', icon: Icons.compare_arrows_outlined),
        data: (context, comparison) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(bidComparisonProvider(args));
            ref.invalidate(rfqDetailProvider(args));
          },
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Text(
                'Sıralama backend\'den geldiği gibi gösterilir. En ucuz teklif otomatik olarak "en iyi" işaretlenmez -- '
                'karar RFQ ekranındaki "Ödüllendir" aksiyonuyla verilir.',
                style: AppTypography.helper,
              ),
              const SizedBox(height: AppSpacing.lg),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: MediaQuery.of(context).size.width - AppSpacing.lg * 2,
                  child: AppComparisonTable(
                    // Varsayılan headerHeight, iki satırlık tedarikçi adı +
                    // "Ödüllendirildi" rozetinin ikisini birden almaya yetmez
                    // (bkz. testte yakalanan taşma) -- bu ekranda başlık her
                    // ikisini de barındırabildiği için daha yüksek.
                    headerHeight: 88,
                    criteriaLabels: [
                      'Toplam Tutar',
                      'Teslimat Süresi',
                      'Geçerlilik',
                      'Ödeme Koşulları',
                      for (final row in comparison.rows) row.item.description,
                    ],
                    columns: [
                      for (final q in comparison.quotations)
                        AppComparisonColumn(
                          isAwarded: awardedQuotationId != null && q.id == awardedQuotationId,
                          header: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                q.supplierName ?? q.supplierId,
                                style: AppTypography.cardTitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (awardedQuotationId != null && q.id == awardedQuotationId) ...[
                                const SizedBox(height: 2),
                                StatusRegistry.awardedQuotation,
                              ],
                            ],
                          ),
                          values: [
                            MoneyText(q.total, currency: q.currency, style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
                            Text(q.deliveryDays != null ? '${q.deliveryDays} gün' : '—', style: AppTypography.body),
                            Text(q.validUntil != null ? Formatters.date(q.validUntil) : '—', style: AppTypography.body),
                            Text(q.paymentTerms.isEmpty ? '—' : q.paymentTerms, style: AppTypography.body, maxLines: 1, overflow: TextOverflow.ellipsis),
                            for (final row in comparison.rows)
                              row.cells[q.supplierId] != null
                                  ? MoneyText(row.cells[q.supplierId]!.unitPrice, currency: q.currency, style: AppTypography.body)
                                  : const Text('—', style: AppTypography.body),
                          ],
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
