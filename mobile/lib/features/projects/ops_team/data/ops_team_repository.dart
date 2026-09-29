import '../../../../core/api/api_client.dart';
import '../domain/project_access.dart';
import '../domain/schedule_item.dart';
import '../domain/team_member.dart';

/// Proje Planlama / Ekip / Erişim uçları (backend router.go, web
/// `OperationSections.tsx` + `AccessSections.tsx` ile AYNI çağrılar):
///
/// Planlama (`projects.operations.read` / `.manage`):
/// - GET  /projects/{id}/schedule            -> `{items: [...]}`
/// - POST /projects/{id}/schedule            -> oluştur (201)
/// - PUT  /projects/{id}/schedule/{itemId}   -> TÜM alanları günceller
///   (silme ucu YOK -- web'de de yok; aşama "İptal" durumuna alınır)
///
/// Ekip (`projects.operations.read` / `.manage`):
/// - GET    /projects/{id}/members             -> `{members: [...]}`
/// - POST   /projects/{id}/members             -> ekibe ekle (201; aynı
///   personel aktifken 409)
/// - DELETE /projects/{id}/members/{memberId}  -> ekipten çıkar (kayıt
///   silinmez, bitiş tarihi bugün yazılır)
/// - GET    /employees?filter=aktif            -> seçici (`employees.read`)
///
/// Erişim (`projects.access.read` / `.manage`):
/// - GET    /projects/{id}/access              -> `{users: [...]}`
/// - POST   /projects/{id}/access              -> `{user_id, project_role}`
/// - PUT    /projects/{id}/access/{userId}     -> `{project_role}`
/// - DELETE /projects/{id}/access/{userId}
/// - GET    /users?limit=200                   -> seçici (Yönetici rolü +
///   `organization.users.read`; `projects.access.manage` sahipleri
///   -- sahip/yönetici -- zaten buna sahip)
class OpsTeamRepository {
  OpsTeamRepository(this._client);
  final ApiClient _client;

  String _project(String projectId) => '/projects/${Uri.encodeComponent(projectId)}';

  // ---------- Planlama ----------

  Future<List<ScheduleItem>> schedule(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('${_project(projectId)}/schedule');
    return (json['items'] as List? ?? const []).cast<Map<String, dynamic>>().map(ScheduleItem.fromJson).toList();
  }

  Future<ScheduleItem> createScheduleItem(String projectId, ScheduleItemInput input) async {
    final json = await _client.post<Map<String, dynamic>>('${_project(projectId)}/schedule', data: input.toJson());
    return ScheduleItem.fromJson(json);
  }

  Future<ScheduleItem> updateScheduleItem(String projectId, String itemId, ScheduleItemInput input) async {
    final json = await _client.put<Map<String, dynamic>>(
      '${_project(projectId)}/schedule/${Uri.encodeComponent(itemId)}',
      data: input.toJson(),
    );
    return ScheduleItem.fromJson(json);
  }

  // ---------- Ekip ----------

  Future<List<ProjectTeamMember>> members(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('${_project(projectId)}/members');
    return (json['members'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(ProjectTeamMember.fromJson)
        .toList();
  }

  Future<ProjectTeamMember> addMember(String projectId, TeamMemberInput input) async {
    final json = await _client.post<Map<String, dynamic>>('${_project(projectId)}/members', data: input.toJson());
    return ProjectTeamMember.fromJson(json);
  }

  Future<ProjectTeamMember> endMembership(String projectId, String memberId) async {
    final json = await _client.delete<Map<String, dynamic>>(
      '${_project(projectId)}/members/${Uri.encodeComponent(memberId)}',
    );
    return ProjectTeamMember.fromJson(json);
  }

  Future<List<EmployeeOption>> activeEmployees() async {
    final json = await _client.get<Map<String, dynamic>>('/employees', query: {'filter': 'aktif'});
    return (json['employees'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(EmployeeOption.fromJson)
        .toList();
  }

  // ---------- Erişim ----------

  Future<List<ProjectAccessUser>> accessUsers(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('${_project(projectId)}/access');
    return (json['users'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(ProjectAccessUser.fromJson)
        .toList();
  }

  Future<void> grantAccess(String projectId, {required String userId, required String projectRole}) =>
      _client.post<void>('${_project(projectId)}/access', data: {'user_id': userId, 'project_role': projectRole});

  Future<void> changeAccessRole(String projectId, {required String userId, required String projectRole}) =>
      _client.put<void>(
        '${_project(projectId)}/access/${Uri.encodeComponent(userId)}',
        data: {'project_role': projectRole},
      );

  Future<void> revokeAccess(String projectId, {required String userId}) =>
      _client.delete<void>('${_project(projectId)}/access/${Uri.encodeComponent(userId)}');

  /// Liste ucu sayfa başına en çok 200 döner (200 üstü limit sessizce 50'ye
  /// düşer) -- web de aynı `limit=200` ile çağırır.
  Future<List<OrgUserOption>> orgUsers() async {
    final json = await _client.get<Map<String, dynamic>>('/users', query: {'limit': 200});
    return (json['users'] as List? ?? const []).cast<Map<String, dynamic>>().map(OrgUserOption.fromJson).toList();
  }
}
