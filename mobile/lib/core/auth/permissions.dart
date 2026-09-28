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

/// Uçları izne EK OLARAK kaba `requireAdmin` kapısının arkasında duran
/// izinler (backend domain.adminRoleOnlyPermissions, web lib/permissions.ts
/// ADMIN_ROLE_ONLY_PERMISSIONS ile BİREBİR aynı): kullanıcı yönetimi, Roller
/// & Yetkiler, e-posta (SMTP) ayarları. Sahip/Yönetici dışındakilerde hiçbir
/// uçta işe yaramaz.
const Set<String> kAdminRoleOnlyPermissions = {
  'organization.users.read',
  'organization.users.manage',
  'organization.roles.read',
  'organization.roles.manage',
  'organization.settings.read',
  'organization.settings.manage',
};

/// Yönetim ekranları (Ürünler, Personel, Kullanıcılar, Roller, Tedarikçiler,
/// Maliyet Kodları, Metraj reçeteleri, ayarlar) için KATI kontrol -- web
/// `canAccess` ile aynı karar. `can`'ın aksine fail-CLOSED: kullanıcı
/// yüklenmemişse ya da izin kümesi boşsa erişim YOK; Yönetici'ye kilitli
/// izinler ayrıca kaba rol admin ister. Menü öğesi, düğme ve form
/// görünürlüğü bununla belirlenir; asıl sınır yine backend'dedir.
extension UserAccess on User? {
  bool canAccess(String code) {
    final user = this;
    if (user == null) return false;
    if (kAdminRoleOnlyPermissions.contains(code) && user.role != UserRole.admin) return false;
    return user.hasPermission(code);
  }
}
