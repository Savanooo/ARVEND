import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// Etiket + değer satırı -- teklif/sipariş/sözleşme/hakediş gibi birçok
/// detay ekranında tekrarlanan `Row(spaceBetween, [Text(label), Text(value)])`
/// kalıbının yerini alır. Uzun Türkçe etiketler/değerler tek satıra
/// sığdırılır (ellipsis) -- bkz. Faz 1'in aynı taşma dersi.
///
/// [multiline]: değer HİÇ kırpılmaz. Etiket ve değer yan yana sığıyorsa
/// düzen aynıdır (değer sağa yaslı); sığmıyorsa (uzun unvan, adres, fiyat
/// esası gibi) değer etiketin ALTINA, sola hizalı ve tam yazılır -- sağa
/// yaslı çok satırlı bir paragraf okunmuyordu.
///
/// [trailing]: değer metni yerine sağda bir bileşen (ör. durum rozeti).
class AppDataRow extends StatelessWidget {
  const AppDataRow({
    super.key,
    required this.label,
    this.value = '',
    this.emphasize = false,
    this.valueColor,
    this.valueStyle,
    this.multiline = false,
    this.trailing,
  });

  final String label;
  final String value;
  final bool emphasize;
  final Color? valueColor;
  final TextStyle? valueStyle;
  final bool multiline;
  final Widget? trailing;

  TextStyle get _valueStyle {
    final base =
        valueStyle ??
        (emphasize
            ? AppTypography.body.copyWith(fontSize: 15, fontWeight: FontWeight.w800)
            : AppTypography.body.copyWith(fontWeight: FontWeight.w600));
    return valueColor == null ? base : base.copyWith(color: valueColor);
  }

  @override
  Widget build(BuildContext context) {
    if (trailing != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          children: [
            Expanded(child: Text(label, style: AppTypography.metadata, maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: AppSpacing.sm),
            trailing!,
          ],
        ),
      );
    }
    if (!multiline) return _inline(maxLines: 1);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.maxWidth.isFinite) return _inline(maxLines: null);
        final available = constraints.maxWidth - AppSpacing.sm;
        final fits =
            _fitsOneLine(context, label, AppTypography.metadata, available * 2 / 5) &&
            _fitsOneLine(context, value, _valueStyle, available * 3 / 5);
        if (fits) return _inline(maxLines: 1);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: AppTypography.metadata),
              const SizedBox(height: 2),
              Text(value, style: _valueStyle.copyWith(height: 1.35)),
            ],
          ),
        );
      },
    );
  }

  Widget _inline({required int? maxLines}) {
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
              maxLines: maxLines,
              overflow: maxLines == null ? null : TextOverflow.ellipsis,
              style: _valueStyle,
            ),
          ),
        ],
      ),
    );
  }

  static bool _fitsOneLine(BuildContext context, String text, TextStyle style, double maxWidth) {
    if (text.contains('\n')) return false;
    final painter = TextPainter(
      text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    final exceeded = painter.didExceedMaxLines;
    painter.dispose();
    return !exceeded;
  }
}
