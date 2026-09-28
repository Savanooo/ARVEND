import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_status_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/viz/paired_bar_chart.dart';
import '../../domain/dashboard.dart';
import '../../domain/dashboard_registry.dart';
import 'section_error_body.dart';

/// "Nakit Akışı" (spec §6.4): son 6 ay ikili çubuk grafiği + "Bu ay"
/// dökümü (tam tutarlar, işaretli). Birden çok para biriminde üstte
/// para birimi seçici -- farklı para birimleri ASLA toplanmaz (D13).
class CashFlowCard extends StatefulWidget {
  const CashFlowCard({super.key, required this.data, this.onRetry});

  final Dashboard data;

  /// Finans bölümü hesaplanamadıysa (section_errors) gövde hata satırıdır.
  final VoidCallback? onRetry;

  @override
  State<CashFlowCard> createState() => _CashFlowCardState();
}

class _CashFlowCardState extends State<CashFlowCard> {
  int _selected = 0;

  /// Finans bölümü var ama hiç hareket yoksa (by_currency boş) sunucunun
  /// dönem başından geriye 6 boş ay -- eksen yine çizilir.
  List<ChartMonth> _emptyMonths() {
    final start = DateTime.tryParse(widget.data.period.monthStart);
    if (start == null) return const [];
    return [
      for (var i = 5; i >= 0; i--)
        () {
          final d = DateTime.utc(start.year, start.month - i);
          final (short, long) = monthLabels('${d.year}-${d.month.toString().padLeft(2, '0')}');
          return ChartMonth(label: short, longLabel: long, inflow: 0, outflow: 0, isCurrent: i == 0);
        }(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (widget.data.sections.finance == null && widget.data.sectionErrors.contains('finance')) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppSectionHeader(title: 'Nakit Akışı'),
          const SizedBox(height: AppSpacing.sm),
          AppCard(child: SectionErrorBody(onRetry: widget.onRetry ?? () {})),
        ],
      );
    }
    final rows = widget.data.sections.finance?.byCurrency ?? const <DashFinanceCurrency>[];
    final index = _selected < rows.length ? _selected : 0;
    final row = rows.isEmpty ? null : rows[index];
    final currency = row?.currency ?? widget.data.primaryCurrency;
    final months = row == null
        ? _emptyMonths()
        : [
            for (var i = 0; i < row.trend6m.length; i++)
              () {
                final t = row.trend6m[i];
                final (short, long) = monthLabels(t.month);
                return ChartMonth(
                  label: short,
                  longLabel: long,
                  inflow: t.collections,
                  outflow: t.outflows,
                  isCurrent: i == row.trend6m.length - 1,
                );
              }(),
          ];
    final allZero = months.every((m) => m.inflow == 0 && m.outflow == 0);
    final month = row?.month;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSectionHeader(
          title: 'Nakit Akışı',
          trailing: Text('Son 6 ay', style: AppTypography.helper),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (rows.length > 1) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: [
                      for (var i = 0; i < rows.length; i++) ButtonSegment(value: i, label: Text(rows[i].currency)),
                    ],
                    selected: {index},
                    onSelectionChanged: (s) => setState(() => _selected = s.first),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              PairedBarChart(months: months, currency: currency),
              const SizedBox(height: AppSpacing.sm),
              if (allZero)
                const Text('Son 6 ayda tahsilat ya da ödeme kaydı yok.', style: AppTypography.helper)
              else
                const Wrap(
                  spacing: AppSpacing.lg,
                  children: [
                    _Legend(color: AppStatusColors.success, label: 'Tahsilat'),
                    _Legend(color: AppColors.textMuted, label: 'Çıkış'),
                  ],
                ),
              if (month != null) ...[
                const SizedBox(height: AppSpacing.md),
                const Divider(height: 1),
                const SizedBox(height: AppSpacing.md),
                const Text('BU AY', style: AppTypography.overline),
                const SizedBox(height: AppSpacing.xs),
                _MonthRow(
                  label: 'Tahsilat',
                  value: Formatters.signedMoney(month.collections, currency: currency),
                ),
                _MonthRow(
                  label: 'Masraf',
                  value: Formatters.signedMoney(-month.expenses, currency: currency),
                ),
                _MonthRow(
                  label: 'Taşeron ödemesi',
                  value: Formatters.signedMoney(-month.subcontractPayments, currency: currency),
                ),
                _MonthRow(
                  label: 'Net',
                  value: Formatters.signedMoney(month.netCash, currency: currency),
                  emphasize: true,
                  valueColor: month.netCash > 0
                      ? AppStatusColors.success
                      : (month.netCash < 0 ? AppStatusColors.error : null),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// "Bu ay" satırı: tam tutar ASLA kesilmez (spec D5 -- dökümde tam değer);
/// dar ekran / büyük yazıda etiket alt satıra sarar.
class _MonthRow extends StatelessWidget {
  const _MonthRow({required this.label, required this.value, this.emphasize = false, this.valueColor});

  final String label;
  final String value;
  final bool emphasize;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final style = emphasize
        ? AppTypography.body.copyWith(fontSize: 15, fontWeight: FontWeight.w800)
        : AppTypography.body.copyWith(fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      // Etiket ve tutar dikeyde ortalanır: farklı punto (metadata / body
      // w600) üstten hizalanınca etiket tutarın taban çizgisinden yukarıda
      // kalıyordu. FittedBox taban çizgisi hizalamasını desteklemez.
      child: Row(
        children: [
          Expanded(flex: 2, child: Text(label, style: AppTypography.metadata)),
          const SizedBox(width: AppSpacing.sm),
          // Sığmazsa kesilmez, küçülür.
          Flexible(
            flex: 3,
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  softWrap: false,
                  style: style.copyWith(color: valueColor, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 6),
        Text(label, style: AppTypography.helper),
      ],
    );
  }
}
