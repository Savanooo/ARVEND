import '../../features/auth/domain/user.dart';

/// Mevcut "fail-open" izin semantiği (bkz. project_detail_screen.dart
/// `_failOpen`): kullanıcı henüz yüklenmemişse ya da izin kümesi boşsa
/// (eski oturum) her şey GÖRÜNÜR -- gerçek sınır HER ZAMAN backend'dedir.
/// Ana sayfada YALNIZCA hızlı işlem butonları ve iskelet tahmini için
/// kullanılır; kartların görünürlüğünü sunucu belirler (spec D2).
extension UserCan on User? {
  bool can(String code) {
    final user = this;
    return user == null || user.permissions.isEmpty || user.hasPermission(code);
  }

  bool canAll(List<String> codes) => codes.every(can);
}
