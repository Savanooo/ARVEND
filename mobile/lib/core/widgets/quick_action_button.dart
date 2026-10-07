import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

const _tilePadding = EdgeInsets.symmetric(vertical: 12, horizontal: 6);
const _iconSize = 40.0;
const _iconLabelGap = 8.0;
final _labelStyle = AppTypography.helper.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w600);

/// Dashboard / Proje Özeti "Hızlı İşlemler" satırındaki tek bir kutucuk --
/// ikon + kısa etiket, tek elle kolay dokunulacak boyutta.
///
/// Tek başına 84 dp genişliğindedir; [QuickActionGrid] içinde ızgaranın
/// verdiği eşit genişlik/yükseklikte çizilir ([fill]).
class QuickActionButton extends StatelessWidget {
  const QuickActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.fill = false,
  });

  final IconData icon;
  final String label;

  /// null = pasif (ör. başka bir hızlı işlem sürerken).
  final VoidCallback? onPressed;

  /// İşlem sürüyor (ör. proje listesi yükleniyor): ikonun yerinde küçük
  /// bir dönen gösterge -- dokunuşun alındığı hemen görünür.
  final bool busy;

  /// Verilen alanı doldur, içeriği dikeyde ortala ve etikete her zaman iki
  /// satırlık yer ayır: tek satırlık ve iki satırlık etiketli kutucukların
  /// ikonları aynı hizada durur (bkz. QuickActionGrid).
  final bool fill;

  QuickActionButton _filled() =>
      QuickActionButton(key: key, icon: icon, label: label, onPressed: onPressed, busy: busy, fill: true);

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: _labelStyle,
    );
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          width: fill ? null : 84,
          padding: _tilePadding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: _iconSize,
                height: _iconSize,
                decoration: BoxDecoration(
                  color: AppColors.gold.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: busy
                    ? const Padding(
                        padding: EdgeInsets.all(11),
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.gold),
                      )
                    : Icon(icon, color: AppColors.gold, size: 20),
              ),
              const SizedBox(height: _iconLabelGap),
              if (fill)
                SizedBox(
                  height: _twoLineLabelHeight(context),
                  child: Align(alignment: Alignment.topCenter, child: text),
                )
              else
                text,
            ],
          ),
        ),
      ),
    );
  }
}

/// İki satırlık etiketin yüksekliği -- kullanıcının yazı boyutu ölçeği ve
/// temanın yazı tipi (Text'in birleştirdiği DefaultTextStyle) dahil.
double _twoLineLabelHeight(BuildContext context) {
  final base = DefaultTextStyle.of(context);
  final painter = TextPainter(
    text: TextSpan(text: 'Ag\nAg', style: base.style.merge(_labelStyle)),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    textHeightBehavior: base.textHeightBehavior,
    maxLines: 2,
  )..layout();
  final height = painter.height;
  painter.dispose();
  return height.ceilToDouble();
}

/// "Hızlı İşlemler" -- Ana Sayfa ve Proje Özeti'nin ORTAK düzeni: bütün
/// işlemler yatay kaydırma OLMADAN, eşit boyutlu kutucuklardan oluşan bir
/// ızgarada görünür. Eskiden yatay kayan bir satırdı: son kutucuk ekran
/// kenarında kesik görünüyor, tek/iki satırlık etiketler kutucukları farklı
/// boylarda bırakıyordu.
///
/// Sütun sayısı genişlikten hesaplanır: varsayılan 4 (360 dp telefonda
/// ~76 dp'lik kutucuk); kutucuk [minTileWidth]'ten daralacaksa daha az,
/// [maxTileWidth]'ten genişleyecekse daha çok sütun. Yükseklik, ikon +
/// iki satırlık etiket (yazı ölçeği dahil) kadar ve hepsinde aynıdır.
class QuickActionGrid extends StatelessWidget {
  const QuickActionGrid({super.key, required this.children});

  final List<QuickActionButton> children;

  static const spacing = AppSpacing.sm;
  static const preferredColumns = 4;
  static const minTileWidth = 72.0;
  static const maxTileWidth = 110.0;

  /// [width] genişliğinde kaç sütun -- testler ve hesap için açık.
  static int columnsFor(double width) {
    double tile(int cols) => (width - spacing * (cols - 1)) / cols;
    var cols = preferredColumns;
    while (cols > 1 && tile(cols) < minTileWidth) {
      cols--;
    }
    while (tile(cols) > maxTileWidth) {
      cols++;
    }
    return cols;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final cols = columnsFor(width);
        // Alt piksel artığı satırı taşırmasın diye aşağı yuvarlanır.
        final tileWidth = ((width - spacing * (cols - 1)) / cols).floorToDouble();
        // Container, kenarlık kalınlığını (üst + alt 1 dp) iç boşluğa ekler.
        final tileHeight = _tilePadding.vertical + 2 + _iconSize + _iconLabelGap + _twoLineLabelHeight(context);
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final child in children)
              SizedBox(
                width: math.max(0, tileWidth),
                height: tileHeight,
                child: child.fill ? child : child._filled(),
              ),
          ],
        );
      },
    );
  }
}
