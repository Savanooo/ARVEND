import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../utils/formatters.dart';

/// Grafikteki tek ay: iki çubuk (giriş/çıkış). Değerler sunucudan hazır
/// gelir (finance.trend_6m) -- istemci hiçbir toplam hesaplamaz.
class ChartMonth {
  const ChartMonth({
    required this.label,
    required this.longLabel,
    required this.inflow,
    required this.outflow,
    this.isCurrent = false,
  });

  /// Eksen etiketi ("Eyl").
  final String label;

  /// Erişilebilirlik metni için ("Eylül 2026").
  final String longLabel;
  final double inflow;
  final double outflow;
  final bool isCurrent;
}

/// "Nakit Akışı · Son 6 ay" ikili çubuk grafiği -- web `PairedBars.tsx` ile
/// AYNI geometri (320x140 görünüm kutusu, çizim alanı x 44-316 / y 8-108,
/// ay başına ~45px grup, 12px çubuk + 3px boşluk, 0/yarı/tepe kesikli
/// ızgara, "güzel tavan" 1-2-2,5-5 x 10^k merdiveni). Grafik kütüphanesi
/// YOK (spec D8); yatayda genişliğe ölçeklenir.
class PairedBarChart extends StatelessWidget {
  const PairedBarChart({
    super.key,
    required this.months,
    required this.currency,
    this.height = 140,
    this.inColor = AppColors.success,
    this.outColor = AppColors.textMuted,
    this.gridColor = AppColors.border,
  });

  final List<ChartMonth> months;
  final String currency;
  final double height;
  final Color inColor;
  final Color outColor;
  final Color gridColor;

  /// En büyük değerin üstündeki ilk "güzel" tavan: 1, 2, 2,5, 5 x 10^k.
  static double niceCeiling(double maxValue) {
    if (maxValue <= 0) return 0;
    final k = (math.log(maxValue) / math.ln10).floor();
    final base = math.pow(10, k).toDouble();
    for (final f in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
      if (f * base >= maxValue - 1e-9) return f * base;
    }
    return 10 * base;
  }

  String _semantics() {
    final parts = [
      for (final m in months)
        '${m.longLabel} — Tahsilat ${Formatters.money(m.inflow, currency: currency)} · '
            'Çıkış ${Formatters.money(m.outflow, currency: currency)}',
    ];
    return 'Nakit akışı, son 6 ay: ${parts.join('; ')}';
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: _semantics(),
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _PairedBarPainter(
              months: months,
              inColor: inColor,
              outColor: outColor,
              gridColor: gridColor,
              textScaler: MediaQuery.textScalerOf(context),
            ),
          ),
        ),
      ),
    );
  }
}

class _PairedBarPainter extends CustomPainter {
  _PairedBarPainter({
    required this.months,
    required this.inColor,
    required this.outColor,
    required this.gridColor,
    required this.textScaler,
  });

  final List<ChartMonth> months;
  final Color inColor;
  final Color outColor;
  final Color gridColor;
  final TextScaler textScaler;

  // Web görünüm kutusu (viewBox 0 0 320 140).
  static const _vbW = 320.0;
  static const _vbH = 140.0;
  static const _plotLeft = 44.0;
  static const _plotRight = 316.0;
  static const _plotTop = 8.0;
  static const _plotBottom = 108.0;
  static const _monthLabelY = 128.0;
  static const _barW = 12.0;
  static const _barGap = 3.0;

  TextPainter _layout(String text, TextStyle style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: textScaler.clamp(maxScaleFactor: 1.3),
    maxLines: 1,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / _vbW;
    final sy = size.height / _vbH;
    double y(double v) => v * sy;

    var maxValue = 0.0;
    for (final m in months) {
      maxValue = math.max(maxValue, math.max(m.inflow, m.outflow));
    }
    final ceiling = PairedBarChart.niceCeiling(maxValue);

    const labelStyle = TextStyle(fontFamily: 'Inter', fontSize: 11, color: AppColors.textMuted);
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    // Izgara: 0, tavan/2, tavan (kesikli "2 3"). Tüm değerler sıfırsa
    // eksen yine çizilir, yalnızca "0" etiketi yazılır (boş durum).
    final gridValues = ceiling == 0 ? const [0.0] : [0.0, ceiling / 2, ceiling];
    final gridLabels = [for (final g in gridValues) _layout(Formatters.compactNumber(g), labelStyle)];
    // Sol boşluk web'deki 44 birimdir; dar ekranda etiket sığmazsa etiket
    // genişliğine göre büyür (etiket kartın dışına taşmasın).
    final widestLabel = gridLabels.fold<double>(0, (w, p) => math.max(w, p.width));
    final plotLeft = math.max(_plotLeft * sx, widestLabel + 6);
    final plotRight = _plotRight * sx;

    for (var i = 0; i < gridValues.length; i++) {
      final g = gridValues[i];
      final gy = y(_plotBottom - (ceiling == 0 ? 0 : g / ceiling * (_plotBottom - _plotTop)));
      for (var gx = plotLeft; gx < plotRight; gx += 5) {
        canvas.drawLine(Offset(gx, gy), Offset(math.min(gx + 2, plotRight), gy), gridPaint);
      }
      final label = gridLabels[i];
      label.paint(canvas, Offset(plotLeft - 6 - label.width, gy - label.height / 2));
    }

    if (months.isEmpty) return;
    final groupW = (plotRight - plotLeft) / months.length;
    final barW = math.min(_barW * sx, groupW * 0.32);
    final barGap = math.min(_barGap * sx, groupW * 0.08);
    for (var i = 0; i < months.length; i++) {
      final m = months[i];
      final center = plotLeft + groupW * i + groupW / 2;
      final left = center - (barW * 2 + barGap) / 2;
      void bar(double value, double bx, Color color) {
        if (ceiling == 0 || value <= 0) return;
        final h = value / ceiling * (_plotBottom - _plotTop);
        final rect = Rect.fromLTRB(bx, y(_plotBottom - h), bx + barW, y(_plotBottom));
        canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(1.5 * sx)), Paint()..color = color);
      }

      bar(m.inflow, left, inColor);
      bar(m.outflow, left + barW + barGap, outColor);
      final label = _layout(
        m.label,
        m.isCurrent ? labelStyle.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w600) : labelStyle,
      );
      label.paint(canvas, Offset(center - label.width / 2, y(_monthLabelY) - label.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _PairedBarPainter old) =>
      old.months != months || old.inColor != inColor || old.outColor != outColor || old.textScaler != textScaler;
}
