/// backend/internal/domain/user.go: Role = "admin" | "kullanici" |
/// "super_admin". super_admin, herhangi bir organizasyona bağlı DEĞİLDİR
/// (organizationId null) -- platform seviyesinde, ARVEND Mobile'da özel bir
/// ekranı yok (bkz. MOBILE_BACKEND_GAPS.md), yalnızca onboarding/must-change-
/// password kontrollerinden muaf tutulmak için tanınması gerekiyor.
enum UserRole {
  admin('admin'),
  kullanici('kullanici'),
  superAdmin('super_admin');

  const UserRole(this.wireValue);
  final String wireValue;

  static UserRole fromWire(String value) => switch (value) {
        'admin' => UserRole.admin,
        'super_admin' => UserRole.superAdmin,
        _ => UserRole.kullanici,
      };
}

/// backend/internal/httpapi/handler/auth_handler.go: userResponse struct.
/// mustChangePassword/onboardingCompleted/onboardingStep, ARVEND — SUPER
/// ADMIN + ONBOARDING fazıyla eklendi (auth_controller.dart'taki router
/// redirect zinciri bunları okur) -- super_admin oturumlarında backend bu
/// alanları her zaman false/true/"completed" sabitleriyle döner (organizasyonu
/// olmadığı için), ayrıca istemci tarafında özel bir dal gerekmez.
class User {
  final String id;
  final String? organizationId;
  final String username;
  final String fullName;
  final UserRole role;
  final bool isActive;
  final bool mustChangePassword;
  final bool onboardingCompleted;
  final String onboardingStep;

  /// super_admin'de her zaman boştur (organizasyona bağlı değil).
  final String organizationName;

  /// organizationRoleCode/-Name: RBAC/Project Membership sprint'inin
  /// ince-taneli organizasyon rolüdür (role'den TAMAMEN AYRI eksen --
  /// bkz. backend/internal/domain/authorization.go). super_admin'de her
  /// zaman boştur.
  final String organizationRoleCode;
  final String organizationRoleName;

  /// permissions: backend'in /auth/me (login/refresh/me) yanıtında dönen
  /// TAM izin kodu kümesidir -- yalnızca UX'te menü/bölüm gizlemek İÇİNDİR,
  /// gerçek güvenlik sınırı HER ZAMAN backend'dedir (her istek ayrıca
  /// sunucuda doğrulanır). super_admin için boştur.
  final Set<String> permissions;

  const User({
    required this.id,
    this.organizationId,
    required this.username,
    required this.fullName,
    required this.role,
    required this.isActive,
    required this.mustChangePassword,
    required this.onboardingCompleted,
    required this.onboardingStep,
    this.organizationName = '',
    this.organizationRoleCode = '',
    this.organizationRoleName = '',
    this.permissions = const {},
  });

  bool hasPermission(String code) => permissions.contains(code);

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        organizationId: json['organization_id'] as String?,
        username: json['username'] as String,
        fullName: json['full_name'] as String,
        role: UserRole.fromWire(json['role'] as String),
        isActive: json['is_active'] as bool,
        mustChangePassword: json['must_change_password'] as bool? ?? false,
        onboardingCompleted: json['onboarding_completed'] as bool? ?? true,
        onboardingStep: json['onboarding_step'] as String? ?? 'completed',
        organizationName: json['organization_name'] as String? ?? '',
        organizationRoleCode: json['organization_role_code'] as String? ?? '',
        organizationRoleName: json['organization_role_name'] as String? ?? '',
        permissions: (json['permissions'] as List<dynamic>?)
                ?.cast<String>()
                .toSet() ??
            const {},
      );

  /// `fromJson`'un tersi (backend alan adlarıyla) -- yalnızca son bilinen
  /// kullanıcıyı telefonda saklamak için (bkz. LastUserStore).
  Map<String, dynamic> toJson() => {
        'id': id,
        'organization_id': organizationId,
        'username': username,
        'full_name': fullName,
        'role': role.wireValue,
        'is_active': isActive,
        'must_change_password': mustChangePassword,
        'onboarding_completed': onboardingCompleted,
        'onboarding_step': onboardingStep,
        'organization_name': organizationName,
        'organization_role_code': organizationRoleCode,
        'organization_role_name': organizationRoleName,
        'permissions': permissions.toList(),
      };
}
