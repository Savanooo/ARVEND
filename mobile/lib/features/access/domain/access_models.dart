import '../../auth/domain/user.dart';

/// GET /users satırı -- backend `userResponse` (bkz. auth_handler.go
/// toUserResponse). `permissions` alanı bu uçta DOLMAZ (yalnızca
/// /auth/me'de); kişinin izinleri ayrıca GET /users/{id}/permissions ile
/// okunur (bkz. [UserPermissionDetail]).
class OrgUser {
  final String id;
  final String username;
  final String fullName;
  final UserRole role;
  final bool isActive;
  final bool mustChangePassword;

  /// Organizasyon rolü (owner/admin/project_manager/finance/field/
  /// legacy_user/...) -- kaba `role` ekseninden TAMAMEN ayrı (bkz.
  /// HANDOFF.md §3). Nadiren (backfill edilmemiş kayıt) boş olabilir.
  final String organizationRoleCode;
  final String organizationRoleName;

  const OrgUser({
    required this.id,
    required this.username,
    required this.fullName,
    required this.role,
    required this.isActive,
    this.mustChangePassword = false,
    this.organizationRoleCode = '',
    this.organizationRoleName = '',
  });

  factory OrgUser.fromJson(Map<String, dynamic> json) => OrgUser(
    id: json['id'] as String,
    username: json['username'] as String? ?? '',
    fullName: json['full_name'] as String? ?? '',
    role: UserRole.fromWire(json['role'] as String? ?? ''),
    isActive: json['is_active'] as bool? ?? true,
    mustChangePassword: json['must_change_password'] as bool? ?? false,
    organizationRoleCode: json['organization_role_code'] as String? ?? '',
    organizationRoleName: json['organization_role_name'] as String? ?? '',
  );

  /// Web Kullanıcılar tablosuyla aynı: organizasyon rolünün adı, yoksa
  /// kaba rolün karşılığı.
  String get roleLabel {
    if (organizationRoleName.isNotEmpty) return organizationRoleName;
    return role == UserRole.admin ? 'Yönetici' : 'Kullanıcı';
  }

  /// Sahip/Yönetici -- web'deki gold rozetin koşulu.
  bool get isOwnerOrAdmin => organizationRoleCode == 'owner' || organizationRoleCode == 'admin';
}

/// GET /organization/roles satırı. Liste "Eski Sistem" (legacy_user)
/// rolünü İÇERMEZ (backend yalnızca atanabilir rolleri döner).
class OrganizationRole {
  final String id;
  final String code;
  final String name;
  final String description;
  final bool isSystem;
  final List<String> permissions;

  const OrganizationRole({
    required this.id,
    required this.code,
    required this.name,
    this.description = '',
    this.isSystem = true,
    this.permissions = const [],
  });

  factory OrganizationRole.fromJson(Map<String, dynamic> json) => OrganizationRole(
    id: json['id'] as String,
    code: json['code'] as String,
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    isSystem: json['is_system'] as bool? ?? true,
    permissions: (json['permissions'] as List<dynamic>?)?.cast<String>() ?? const [],
  );

  bool get isOwner => code == kOwnerRoleCode;
}

/// GET /organization/permissions -- izin kataloğu. `category` web'deki
/// bölüm başlığıdır (Projeler, Finans, Firma Yönetimi...).
class PermissionDef {
  final String code;
  final String description;
  final String category;

  const PermissionDef({required this.code, required this.description, required this.category});

  factory PermissionDef.fromJson(Map<String, dynamic> json) => PermissionDef(
    code: json['code'] as String,
    description: json['description'] as String? ?? '',
    category: json['category'] as String? ?? '',
  );
}

/// GET/PUT /users/{id}/permissions -- kişiye özel yetkiler. `permissions`
/// ETKİN kümedir: (rolPermissions − revoked) ∪ granted. `editable=false`:
/// Sahip (her zaman tüm yetkiler) ya da rolü olmayan kullanıcı.
class UserPermissionDetail {
  final String roleCode;
  final String roleName;
  final List<String> rolePermissions;
  final List<String> permissions;
  final List<String> granted;
  final List<String> revoked;
  final bool editable;

  const UserPermissionDetail({
    required this.roleCode,
    required this.roleName,
    this.rolePermissions = const [],
    this.permissions = const [],
    this.granted = const [],
    this.revoked = const [],
    this.editable = true,
  });

  factory UserPermissionDetail.fromJson(Map<String, dynamic> json) {
    List<String> list(String key) => (json[key] as List<dynamic>?)?.cast<String>() ?? const [];
    return UserPermissionDetail(
      roleCode: json['role_code'] as String? ?? '',
      roleName: json['role_name'] as String? ?? '',
      rolePermissions: list('role_permissions'),
      permissions: list('permissions'),
      granted: list('granted'),
      revoked: list('revoked'),
      editable: json['editable'] as bool? ?? false,
    );
  }
}

/// GET /users/{id}/projects -- "Atandığı Projeler".
class UserProjectAssignment {
  final String projectId;
  final String projectNo;
  final String projectName;
  final String projectRole;

  const UserProjectAssignment({
    required this.projectId,
    required this.projectNo,
    required this.projectName,
    required this.projectRole,
  });

  factory UserProjectAssignment.fromJson(Map<String, dynamic> json) => UserProjectAssignment(
    projectId: json['project_id'] as String,
    projectNo: json['project_no'] as String? ?? '',
    projectName: json['project_name'] as String? ?? '',
    projectRole: json['project_role'] as String? ?? '',
  );

  String get projectRoleLabel => kProjectRoleLabels[projectRole] ?? projectRole;
}

const kOwnerRoleCode = 'owner';

/// Web `PROJECT_ROLE_LABELS` ile birebir.
const kProjectRoleLabels = {'project_manager': 'Proje Yöneticisi', 'member': 'Üye', 'viewer': 'Görüntüleyici'};
