import 'package:flutter/material.dart';

/// Web ARVEND ile aynı marka dili. Gold yalnızca vurgu/CTA/seçili durumda
/// kullanılır - bkz. AppTheme. Marka rengi (gold) ile durum rengi (success/
/// warning/danger/info) KASITLI OLARAK ayrı iki kavramdır -- gold hiçbir
/// zaman bir durumu (ör. "uyarı") temsil etmez, bkz. AppStatusColors
/// (app_status_colors.dart) ve status_badge.dart.
abstract final class AppColors {
  static const navDark = Color(0xFF111827);
  static const background = Color(0xFFF8FAFC);
  static const surface = Color(0xFFFFFFFF);
  static const border = Color(0xFFE2E8F0);
  static const textPrimary = Color(0xFF0F172A);
  static const textMuted = Color(0xFF64748B);
  static const gold = Color(0xFFD89A22);

  static const danger = Color(0xFFDC2626);
  static const success = Color(0xFF16A34A);
  static const warning = Color(0xFFD97706);
  static const info = Color(0xFF2563EB);
}
