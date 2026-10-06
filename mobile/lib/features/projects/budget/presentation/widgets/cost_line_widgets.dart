import 'package:flutter/material.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_spacing.dart';
import '../../../../../core/theme/app_typography.dart';
import '../../../../../core/utils/formatters.dart';
import '../../../../../core/widgets/app_buttons.dart';
import '../../../../../core/widgets/app_card.dart';
import '../../../../../core/widgets/app_data_row.dart';
import '../../../../../core/widgets/status_badge.dart';
import '../../../../../core/widgets/viz/progress_bar.dart';
import '../../domain/budget.dart';
import 'budget_ui.dart';
import '../../../../../core/widgets/app_sheet.dart';

String costLineTitle(CostControlLine l) =>
    l.costCodeName.isEmpty ? l.costCodeCode : '${l.costCodeCode} — ${l.costCodeName}';

String costLineSubtitle(CostControlLine l) =>
    [if (l.wbsCode.isNotEmpty) l.wbsCode, if (l.description.isNotEmpty) l.description].join(' · ');

/// Maliyet kırılımının tek satırı (web "Özet" tablosunun mobil kartı):
/// başlık tam genişlikte; EAC'nin revize bütçeye oranını gösteren ince
/// çubuk; altında EAC/revize ve işaretli, renkli varyans. Bütçe dışı satır
/// rozetle vurgulanır. Tam döküm dokununca açılır.
class CostLineCard extends StatelessWidget {
  const CostLineCard({super.key, required this.line, required this.currency, this.onTap});

  final CostControlLine line;
  final String currency;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l = line;
    final subtitle = costLineSubtitle(l);
    final tabular = const [FontFeature.tabularFigures()];
    return AppCard(
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  costLineTitle(l),
                  style: AppTypography.cardTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (l.isUnbudgeted) ...[
                const SizedBox(width: AppSpacing.sm),
                const StatusBadge(label: 'Bütçe Dışı', tone: StatusTone.danger),
              ],
            ],
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(subtitle, style: AppTypography.metadata, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: AppSpacing.sm),
          AppProgressBar(
            pct: eacUsagePct(l.eac, l.revisedBudget),
            color: isOverBudget(l.variance) ? AppColors.danger : AppColors.success,
            height: 4,
            semanticsLabel: 'Tahmini nihai maliyetin revize bütçeye oranı',
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(text: 'EAC  ', style: AppTypography.helper),
                          TextSpan(
                            text: Formatters.money(l.eac, currency: currency),
                            style: AppTypography.body.copyWith(fontWeight: FontWeight.w700, fontFeatures: tabular),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'Revize ${Formatters.money(l.revisedBudget, currency: currency)}',
                      style: AppTypography.helper.copyWith(fontFeatures: tabular),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('Varyans', style: AppTypography.helper),
                  Text(
                    Formatters.signedMoney(l.variance, currency: currency),
                    style: AppTypography.body.copyWith(
                      color: varianceColor(l.variance),
                      fontWeight: FontWeight.w700,
                      fontFeatures: tabular,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Satır detayından seçilen aksiyon (sayfa kapandıktan sonra çağıran açar).
enum CostLineAction { forecast, adjust }

/// Kırılım satırının tam dökümü -- web tablosunun 11 sütunu. Aksiyonlar
/// yalnızca izin/durum uygunsa gösterilir; seçilen aksiyon döner.
Future<CostLineAction?> showCostLineSheet(
  BuildContext context, {
  required CostControlLine line,
  required String currency,
  required bool canForecast,
  required bool canAdjust,
  bool hasForecastOverride = false,
}) {
  return showAppSheet<CostLineAction>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) {
      final l = line;
      final subtitle = costLineSubtitle(l);
      return SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(costLineTitle(l), style: AppTypography.pageTitle.copyWith(fontSize: 17)),
            if (subtitle.isNotEmpty) ...[const SizedBox(height: 2), Text(subtitle, style: AppTypography.metadata)],
            if (l.isUnbudgeted || isOverBudget(l.variance)) ...[
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  if (l.isUnbudgeted) const StatusBadge(label: 'Bütçe Dışı', tone: StatusTone.danger),
                  if (isOverBudget(l.variance)) const StatusBadge(label: 'Bütçe aşımı', tone: StatusTone.danger),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            AppDataRow(
              label: 'Orijinal Bütçe',
              value: Formatters.money(l.originalBudget, currency: currency),
            ),
            AppDataRow(
              label: 'Onaylı Revizyonlar',
              value: Formatters.signedMoney(l.approvedAdjustments, currency: currency),
            ),
            AppDataRow(
              label: 'Revize Bütçe',
              value: Formatters.money(l.revisedBudget, currency: currency),
              emphasize: true,
            ),
            const Divider(height: AppSpacing.lg),
            AppDataRow(
              label: 'Taahhüt',
              value: Formatters.money(l.committedCost, currency: currency),
            ),
            AppDataRow(
              label: 'Gerçekleşen',
              value: Formatters.money(l.actualCost, currency: currency),
            ),
            AppDataRow(
              label: hasForecastOverride ? 'ETC (manuel)' : 'ETC',
              value: Formatters.money(l.etc, currency: currency),
            ),
            AppDataRow(
              label: 'EAC',
              value: Formatters.money(l.eac, currency: currency),
              emphasize: true,
            ),
            AppDataRow(
              label: 'Varyans',
              value: Formatters.signedMoney(l.variance, currency: currency),
              valueColor: varianceColor(l.variance),
            ),
            if (l.isUnbudgeted) ...[
              const SizedBox(height: AppSpacing.md),
              const BudgetInfoNote(
                'Bu satırın bir bütçe kalemi yok — yalnızca bu maliyet koduna doğrudan bağlanmış (bütçe dışı) '
                'taahhüt/gider var.',
              ),
            ],
            if (canForecast) ...[
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: hasForecastOverride ? 'ETC Düzenle' : 'Manuel ETC Gir',
                icon: Icons.trending_up,
                onPressed: () => Navigator.of(context).pop(CostLineAction.forecast),
              ),
            ],
            if (canAdjust) ...[
              const SizedBox(height: AppSpacing.sm),
              SecondaryButton(
                label: 'Revize Et',
                icon: Icons.published_with_changes_outlined,
                onPressed: () => Navigator.of(context).pop(CostLineAction.adjust),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(foregroundColor: AppColors.textMuted),
              child: const Text('Kapat'),
            ),
          ],
        ),
      );
    },
  );
}
