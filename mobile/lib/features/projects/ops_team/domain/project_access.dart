/// Proje Erişimi (`project_users`, RBAC/Project Membership sprint'i) --
/// UYGULAMA KULLANICILARININ (login hesabı olan) bu projeye erişimi.
/// "Proje Ekibi" (`project_members`, personel roster'ı) İLE
/// KARIŞTIRILMAMALI (bkz. team_member.dart).
library;

/// Proje rol kodları -- backend `domain.ProjectRole*` ile BİREBİR. Proje
/// rolü organizasyon rolünden tamamen ayrı bir eksendir ve ikinci bir izin
/// motoru DEĞİLDİR (backend/docs/authorization.md §3): yalnızca proje içi
/// etikettir.
abstract final class ProjectRole {
  static const projectManager = 'project_manager';
  static const member = 'member';
  static const viewer = 'viewer';

  static const values = [projectManager, member, viewer];

  /// Web `PROJECT_ROLE_LABELS` ile aynı.
  static const labels = {
    projectManager: 'Proje Yöneticisi',
    member: 'Üye',
    viewer: 'Görüntüleyici',
  };

  static String label(String code) => labels[code] ?? code;
}

/// Web `ORG_ROLE_LABELS` ile aynı (kullanıcı seçicisindeki "Ad — Rol").
const kOrgRoleLabels = {
  'owner': 'Sahip (Owner)',
  'admin': 'Yönetici',
  'project_manager': 'Proje Yöneticisi',
  'finance': 'Finans',
  'field': 'Saha',
};

/// `GET /projects/{id}/access` satırı (backend `projectUserResponse`).
class ProjectAccessUser {
  const ProjectAccessUser({
    required this.userId,
    required this.username,
    required this.fullName,
    this.userIsActive = true,
    this.projectRole = ProjectRole.member,
    this.organizationRoleCode = '',
    this.organizationRoleName = '',
  });

  final String userId;
  final String username;
  final String fullName;
  final bool userIsActive;
  final String projectRole;
  final String organizationRoleCode;
  final String organizationRoleName;

  factory ProjectAccessUser.fromJson(Map<String, dynamic> json) => ProjectAccessUser(
        userId: json['user_id'] as String,
        username: json['username'] as String? ?? '',
        fullName: json['full_name'] as String? ?? '',
        userIsActive: json['user_is_active'] as bool? ?? true,
        projectRole: json['project_role'] as String? ?? ProjectRole.member,
        organizationRoleCode: json['organization_role_code'] as String? ?? '',
        organizationRoleName: json['organization_role_name'] as String? ?? '',
      );
}

/// Erişim verilebilecek kullanıcı (`GET /users?limit=200`) -- web
/// `OrgUserOption` ile aynı alt küme.
class OrgUserOption {
  const OrgUserOption({
    required this.id,
    required this.fullName,
    required this.username,
    this.isActive = true,
    this.organizationRoleCode = '',
    this.organizationRoleName = '',
  });

  final String id;
  final String fullName;
  final String username;
  final bool isActive;
  final String organizationRoleCode;
  final String organizationRoleName;

  factory OrgUserOption.fromJson(Map<String, dynamic> json) => OrgUserOption(
        id: json['id'] as String,
        fullName: json['full_name'] as String? ?? '',
        username: json['username'] as String? ?? '',
        isActive: json['is_active'] as bool? ?? true,
        organizationRoleCode: json['organization_role_code'] as String? ?? '',
        organizationRoleName: json['organization_role_name'] as String? ?? '',
      );

  /// Web seçicisiyle aynı: "Ad — Organizasyon rolü".
  String get label {
    if (organizationRoleCode.isEmpty) return fullName;
    final role = kOrgRoleLabels[organizationRoleCode] ??
        (organizationRoleName.isNotEmpty ? organizationRoleName : organizationRoleCode);
    return '$fullName — $role';
  }
}

/// Seçicide gösterilecek kullanıcılar: aktif ve projede henüz erişimi
/// olmayanlar (web `available` ile aynı süzme).
List<OrgUserOption> grantableUsers(List<OrgUserOption> all, List<ProjectAccessUser> assigned) {
  final assignedIds = {for (final u in assigned) u.userId};
  return [
    for (final u in all)
      if (u.isActive && !assignedIds.contains(u.id)) u,
  ];
}
