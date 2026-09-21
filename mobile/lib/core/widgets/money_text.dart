import 'package:flutter/material.dart';

import '../theme/app_typography.dart';
import '../utils/formatters.dart';

/// Para gösterimi -- `Formatters.money` üzerine, her yerde tutarlı
/// `tabularFigures` (rakamlar hizalı kalır) ekler. Hiçbir toplam burada
/// YENİDEN hesaplanmaz, yalnızca zaten hesaplanmış bir değeri biçimler.
class MoneyText extends StatelessWidget {
  const MoneyText(
    this.amount, {
    super.key,
    this.currency = 'TRY',
    this.style,
    this.color,
  });

  final num amount;
  final String currency;
  final TextStyle? style;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final base = style ?? AppTypography.body;
    return Text(
      Formatters.money(amount, currency: currency),
      style: base.merge(TextStyle(color: color, fontFeatures: const [FontFeature.tabularFigures()])),
    );
  }
}
