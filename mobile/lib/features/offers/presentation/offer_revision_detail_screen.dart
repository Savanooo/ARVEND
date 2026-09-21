import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/money_text.dart';
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

    return AppPageScaffold(
      title: const Text('Revizyon Detayı'),
      body: AsyncStateView<OfferRevision>(
        value: async,
        onRetry: () async => ref.invalidate(offerRevisionDetailProvider(key)),
        data: (context, rev) {
          final isCurrent = currentNo != null && rev.revisionNo == currentNo;
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Row(
                children: [
                  StatusRegistry.build(rev.status, StatusRegistry.offer),
                  if (isCurrent) ...[
                    const SizedBox(width: AppSpacing.sm),
                    const Chip(label: Text('Güncel'), visualDensity: VisualDensity.compact),
                  ],
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text('Revizyon #${rev.revisionNo}', style: AppTypography.pageTitle),
              Text(Formatters.dateTime(rev.createdAt), style: AppTypography.metadata),
              const SizedBox(height: AppSpacing.lg),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(rev.customerName, style: AppTypography.cardTitle),
                    if (rev.customerPhone.isNotEmpty) Text(rev.customerPhone, style: AppTypography.body),
                    if (rev.notes.isNotEmpty) ...[const Divider(height: AppSpacing.xl), Text(rev.notes, style: AppTypography.body)],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              const AppSectionHeader(title: 'Kalemler'),
              const SizedBox(height: AppSpacing.sm),
              if (rev.items.isEmpty)
                const EmptyStateView(message: 'Kalem yok.', icon: Icons.description_outlined)
              else
                ...rev.items.map((item) => AppListCard(
                      title: item.productName,
                      subtitle:
                          '${item.quantity} ${item.unit} × ${Formatters.money(item.unitPrice, currency: rev.currency)}'
                          '${canReadInternal && item.hasInternalPricing && item.internalSubcontractCost != null ? '  ·  İç maliyet: ${Formatters.money(item.internalSubcontractCost!, currency: rev.currency)}' : ''}',
                      trailing: MoneyText(item.lineTotal, currency: rev.currency, style: AppTypography.body.copyWith(fontWeight: FontWeight.w700)),
                    )),
              AppCard(
                margin: const EdgeInsets.only(top: AppSpacing.sm),
                child: Column(
                  children: [
                    AppDataRow(label: 'Ara Toplam', value: Formatters.money(rev.subtotal, currency: rev.currency)),
                    AppDataRow(
                      label: 'KDV (%${rev.vatRate.toStringAsFixed(0)})',
                      value: Formatters.money(rev.vatAmount, currency: rev.currency),
                    ),
                    const Divider(),
                    AppDataRow(label: 'Genel Toplam', value: Formatters.money(rev.grandTotal, currency: rev.currency), emphasize: true),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text('Geçmiş revizyonlar değiştirilemez.', style: AppTypography.helper),
            ],
          );
        },
      ),
    );
  }
}
