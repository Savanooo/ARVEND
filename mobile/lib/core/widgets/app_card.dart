import 'package:flutter/material.dart';

import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';

/// Standart iç dolgulu kart -- `Card(child: Padding(padding: EdgeInsets.
/// all(16), ...))` tekrarının yerini alır. Kart görünümünün kendisi
/// (renk/kenarlık/köşe) global `CardThemeData`'dan (bkz. AppTheme) gelir,
/// burada YENİDEN tanımlanmaz.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.margin,
    this.onTap,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final VoidCallback? onTap;
  // Yalnızca bilinçli vurgu kartları için (ör. Dashboard'un kompakt marka
  // kartı) -- normal kartlar bunu ASLA vermemeli, global temadan miras alır.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    return Card(
      margin: margin ?? EdgeInsets.zero,
      color: color,
      child: onTap == null
          ? content
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: content,
            ),
    );
  }
}
