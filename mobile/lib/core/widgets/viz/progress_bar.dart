import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Ana sayfanın tek yüzdelik çubuğu (spec D8 -- grafik kütüphanesi YOK).
/// Değer 0-100 aralığına kıstırılır; 0 (ya da null) hiç dolgu çizmez.
/// Yüzdeyi istemci HESAPLAMAZ -- sunucunun verdiği değeri yalnızca çizer.
class AppProgressBar extends StatelessWidget {
  const AppProgressBar({super.key, required this.pct, required this.color, this.semanticsLabel, this.height = 6});

  final double? pct;
  final Color color;
  final String? semanticsLabel;
  final double height;

  @override
  Widget build(BuildContext context) {
    final value = (pct ?? 0).clamp(0, 100) / 100;
    return Semantics(
      label: semanticsLabel,
      value: pct == null ? null : '%${(pct!.clamp(0, 100)).round()}',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: ColoredBox(
            color: AppColors.border,
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: value.toDouble(),
                heightFactor: 1,
                child: ColoredBox(color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
