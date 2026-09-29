import 'package:flutter/material.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_spacing.dart';
import '../../../../../core/theme/app_typography.dart';
import '../../../../../core/utils/formatters.dart';
import '../../../../../core/widgets/app_card.dart';
import '../../domain/project_change_order.dart';
import 'contract_co_ui.dart';

/// Sözleşme bedeli kırılımı -- web proje sayfasındaki "Genel / Fiyat"
/// kırılımı (Ana Sözleşme Bedeli + Onaylı Ek İşler + Onaylı Eksiltmeler =
/// Güncel Proje Bedeli) ve FinanceSummary'nin "onay bekleyen" satırı.
/// Tüm rakamlar `financial-summary`'den gelir; burada toplanmaz. Yalnızca
/// `projects.finance.read` sahibine çizilir (çağıran denetler).
class ContractValueCard extends StatelessWidget {
  const ContractValueCard({super.key, required this.summary});

  final ContractValueSummary summary;

  @override
  Widget build(BuildContext context) {
    final c = summary.currency;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Güncel Proje Bedeli', style: AppTypography.metadata),
          const SizedBox(height: 2),
          Text(
            Formatters.money(summary.currentContractValue, currency: c),
            style: AppTypography.metricPrimary.copyWith(color: AppColors.gold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const Divider(height: AppSpacing.xl),
          ContractCoValueRow(label: 'Ana Sözleşme Bedeli', value: Formatters.money(summary.baseContractAmount, currency: c)),
          ContractCoValueRow(
            label: 'Onaylı Ek İşler',
            value: Formatters.signedMoney(summary.approvedAdditions, currency: c),
            valueColor: summary.approvedAdditions > 0 ? AppColors.success : null,
          ),
          ContractCoValueRow(
            label: 'Onaylı Eksiltmeler',
            value: Formatters.signedMoney(-summary.approvedDeductions, currency: c),
            valueColor: summary.approvedDeductions > 0 ? AppColors.danger : null,
          ),
          // Potansiyel değer GERÇEK güncel bedelle karıştırılmamalı -- bilgi
          // amaçlı, ayrı ve soluk (web FinanceSummary ile aynı ilke).
          if (summary.hasPending) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Onay bekleyen ek iş: ${Formatters.signedMoney(summary.pendingNet, currency: c)} — '
              'Potansiyel proje bedeli: ${Formatters.money(summary.potentialContractValue, currency: c)}',
              style: AppTypography.helper.copyWith(height: 1.35),
            ),
          ],
        ],
      ),
    );
  }
}
