import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// Etiket + değer satırı -- teklif/sipariş/sözleşme/hakediş gibi birçok
/// detay ekranında tekrarlanan `Row(spaceBetween, [Text(label), Text(value)])`
/// kalıbının yerini alır. Uzun Türkçe etiketler/değerler tek satıra
/// sığdırılır (ellipsis) -- bkz. Faz 1'in aynı taşma dersi.
class AppDataRow extends StatelessWidget {
  const AppDataRow({
    super.key,
    required this.label,
    required this.value,
    this.emphasize = false,
    this.valueColor,
  });

  final String label;
  final String value;
  final bool emphasize;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            flex: 2,
            child: Text(label, style: AppTypography.metadata, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            flex: 3,
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (emphasize ? AppTypography.body.copyWith(fontSize: 15, fontWeight: FontWeight.w800) : AppTypography.body.copyWith(fontWeight: FontWeight.w600))
                  .copyWith(color: valueColor),
            ),
          ),
        ],
      ),
    );
  }
}
