import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';

/// Tek bir bölüt: etiket + sayı + renk. `dashed` "Girilmedi" gibi değeri
/// olan ama renkle dolmayan (kesikli çerçeveli) bölüt içindir;
/// `legendOnly` bölüt çubukta çizilmez, yalnızca açıklamada renk noktası
/// OLMADAN görünür (ör. Projeler kartındaki "· İptal 1"; `color` kullanılmaz).
class SegmentData {
  const SegmentData({
    required this.label,
    required this.value,
    required this.color,
    this.dashed = false,
    this.legendOnly = false,
  });

  final String label;
  final int value;
  final Color color;
  final bool dashed;
  final bool legendOnly;
}

/// Oransal yatay bölüt çubuğu + isteğe bağlı açıklama (spec D8). Bölütler
/// arasında 1px boşluk, değeri olan her bölüt en az 2px -- oranları
/// istemci yalnızca ÇİZER, sayıları sunucu verir.
class AppSegmentBar extends StatelessWidget {
  const AppSegmentBar({super.key, required this.segments, this.legend = true, this.height = 8, this.semanticsLabel});

  final List<SegmentData> segments;
  final bool legend;
  final double height;
  final String? semanticsLabel;

  static const _gap = 1.0;
  static const _minWidth = 2.0;

  List<double> _widths(double available, List<SegmentData> drawn) {
    final total = drawn.fold<int>(0, (sum, s) => sum + s.value);
    if (total <= 0 || drawn.isEmpty) return const [];
    final usable = (available - _gap * (drawn.length - 1)).clamp(0.0, double.infinity);
    final widths = [for (final s in drawn) (usable * s.value / total).clamp(_minWidth, double.infinity).toDouble()];
    final excess = widths.fold<double>(0, (a, b) => a + b) - usable;
    if (excess > 0) {
      // En az 2px kuralının taştığı kısmı en geniş bölütten düş.
      var widest = 0;
      for (var i = 1; i < widths.length; i++) {
        if (widths[i] > widths[widest]) widest = i;
      }
      widths[widest] = (widths[widest] - excess).clamp(_minWidth, double.infinity);
    }
    return widths;
  }

  @override
  Widget build(BuildContext context) {
    final drawn = [
      for (final s in segments)
        if (!s.legendOnly && s.value > 0) s,
    ];
    final label = semanticsLabel ?? segments.map((s) => '${s.label} ${s.value}').join(', ');
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: height,
                width: double.infinity,
                child: ColoredBox(
                  color: drawn.isEmpty ? AppColors.border : Colors.transparent,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final widths = _widths(constraints.maxWidth, drawn);
                      return Row(
                        children: [
                          for (var i = 0; i < widths.length; i++) ...[
                            if (i > 0) const SizedBox(width: _gap),
                            SizedBox(
                              width: widths[i],
                              height: height,
                              child: drawn[i].dashed
                                  ? CustomPaint(painter: _DashedRectPainter(AppColors.textMuted))
                                  : ColoredBox(color: drawn[i].color),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            if (legend) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 12, runSpacing: 4, children: [for (final s in segments) _LegendItem(segment: s)]),
            ],
          ],
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.segment});
  final SegmentData segment;

  @override
  Widget build(BuildContext context) {
    final text = AppTypography.helper.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    // Çubukta olmayan kalem renk noktası taşımaz ("· İptal 1", web
    // legendExtra ile aynı) -- renk yalnızca çizilen bölütlere aittir.
    if (segment.legendOnly) return Text('· ${segment.label} ${segment.value}', style: text);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 8,
          height: 8,
          child: segment.dashed
              ? CustomPaint(painter: _DashedRectPainter(AppColors.textMuted))
              : DecoratedBox(
                  decoration: BoxDecoration(color: segment.color, borderRadius: BorderRadius.circular(2)),
                ),
        ),
        const SizedBox(width: 6),
        Flexible(child: Text('${segment.label} ${segment.value}', style: text)),
      ],
    );
  }
}

/// "Girilmedi" bölütünün kesikli çerçevesi.
class _DashedRectPainter extends CustomPainter {
  _DashedRectPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    const dash = 2.0;
    const space = 2.0;
    void dashed(Offset a, Offset b) {
      final length = (b - a).distance;
      if (length == 0) return;
      final dir = (b - a) / length;
      for (var d = 0.0; d < length; d += dash + space) {
        final end = (d + dash).clamp(0.0, length);
        canvas.drawLine(a + dir * d, a + dir * end, paint);
      }
    }

    final r = Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1);
    dashed(r.topLeft, r.topRight);
    dashed(r.topRight, r.bottomRight);
    dashed(r.bottomRight, r.bottomLeft);
    dashed(r.bottomLeft, r.topLeft);
  }

  @override
  bool shouldRepaint(covariant _DashedRectPainter oldDelegate) => oldDelegate.color != color;
}
