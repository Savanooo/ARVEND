import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Adlandırılmış tipografi ölçeği -- ekranlarda onlarca ilgisiz
/// `TextStyle(fontSize: N)` yerine bu sabitler kullanılır. Para/miktar
/// gösteren her yerde `tabularFigures` ile rakamlar hizalı kalır (bkz.
/// MoneyText).
abstract final class AppTypography {
  static const pageTitle = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w800,
    color: AppColors.textPrimary,
    height: 1.25,
    letterSpacing: -0.2,
  );

  static const sectionTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
  );

  static const cardTitle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
  );

  static const metricPrimary = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w800,
    color: AppColors.textPrimary,
    height: 1.1,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Ana sayfa KPI kutucuğunun büyük değeri.
  static const metricHero = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w800,
    color: AppColors.textPrimary,
    height: 1.1,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Küçük büyük-harfli bölüm etiketi (ana sayfa bant başlıkları, Dikkat
  /// şeritleri). Metin ÇAĞIRAN tarafından büyük harfle yazılır --
  /// `toUpperCase()` Türkçe "i"yi bozar.
  static const overline = TextStyle(
    fontSize: 11.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.8,
    color: AppColors.textMuted,
  );

  static const body = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
  );

  static const metadata = TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
    color: AppColors.textMuted,
  );

  static const helper = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: AppColors.textMuted,
  );

  static const error = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: AppColors.danger,
  );
}
