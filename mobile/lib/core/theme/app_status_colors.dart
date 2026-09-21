import 'app_colors.dart';

/// Anlamsal durum renkleri -- `AppColors`'ın marka/nötr paletinden ayrı,
/// KASITLI bir katman: bir figürün "iyi/kötü/dikkat" anlamını taşır (ör.
/// `MoneyText`, `MetricCard`), `StatusBadge`'in kendi durum-kaydı
/// sisteminden (bkz. status_badge.dart `StatusRegistry`) bağımsız olarak
/// kullanılabilir. `AppColors.gold` burada YOKTUR -- marka vurgusu bir
/// durum anlamı taşımaz.
abstract final class AppStatusColors {
  static const neutral = AppColors.textMuted;
  static const info = AppColors.info;
  static const success = AppColors.success;
  static const warning = AppColors.warning;
  static const error = AppColors.danger;
}
