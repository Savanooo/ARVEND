import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// Bir tedarikçi/teklif sütunu -- `values`, `AppComparisonTable.criteriaLabels`
/// ile AYNI sırada ve AYNI uzunlukta olmalıdır (çağıran sorumludur).
/// `isAwarded`, backend'in ZATEN belirlediği kazananı (ör.
/// `RFQ.awardedQuotationId`) yansıtır -- burada en ucuzu "en iyi" diye
/// İŞARETLEYEN hiçbir istemci-taraflı hesap YOKTUR.
class AppComparisonColumn {
  const AppComparisonColumn({required this.header, required this.values, this.isAwarded = false});

  final Widget header;
  final List<Widget> values;
  final bool isAwarded;
}

/// Teklif Karşılaştırma için sabit sol "kriter" sütunu + yatay kaydırmalı
/// tedarikçi sütunları -- yığılmış kartların (gerçek yan yana karşılaştırma
/// SAĞLAMAYAN) yerini alır. Her satır (kriter + değer hücreleri) sabit bir
/// yükseklikte render edilir ki sol sütun ile kaydırılan sütunlar HER ZAMAN
/// hizalı kalsın.
class AppComparisonTable extends StatelessWidget {
  const AppComparisonTable({
    super.key,
    required this.criteriaLabels,
    required this.columns,
    this.criteriaWidth = 128,
    this.columnWidth = 152,
    this.rowHeight = 44,
    this.headerHeight = 64,
  });

  final List<String> criteriaLabels;
  final List<AppComparisonColumn> columns;
  final double criteriaWidth;
  final double columnWidth;
  final double rowHeight;
  final double headerHeight;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: criteriaWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: headerHeight),
              for (final label in criteriaLabels)
                Container(
                  height: rowHeight,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
                  child: Text(label, style: AppTypography.metadata, maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final col in columns) _ComparisonColumnView(col: col, width: columnWidth, rowHeight: rowHeight, headerHeight: headerHeight)],
            ),
          ),
        ),
      ],
    );
  }
}

class _ComparisonColumnView extends StatelessWidget {
  const _ComparisonColumnView({required this.col, required this.width, required this.rowHeight, required this.headerHeight});

  final AppComparisonColumn col;
  final double width;
  final double rowHeight;
  final double headerHeight;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      margin: const EdgeInsets.only(left: AppSpacing.sm),
      decoration: BoxDecoration(
        color: col.isAwarded ? AppColors.success.withValues(alpha: 0.05) : null,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: col.isAwarded ? Border.all(color: AppColors.success.withValues(alpha: 0.45)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: headerHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
              child: col.header,
            ),
          ),
          for (final value in col.values)
            Container(
              height: rowHeight,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border))),
              child: value,
            ),
        ],
      ),
    );
  }
}
