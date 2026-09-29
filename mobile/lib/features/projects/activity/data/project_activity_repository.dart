import '../../../../core/api/api_client.dart';
import '../domain/project_event.dart';

/// Proje "Aktivite" (web proje sayfasının Aktivite sekmesi,
/// `ProjectActivitySection`):
///
/// - GET /projects/{id}/events -> `{events: [{id, event_type, user_id,
///   metadata, created_at}]}` (created_at ASC). `projPerm(projects.read)`:
///   izin + proje üyeliği SUNUCUDA denetlenir.
///
/// Uç tutar alanlarını da döndürür; bunları gösterip göstermemek istemcinin
/// işidir (bkz. `kProjectEventMoneyKeys`).
class ProjectActivityRepository {
  ProjectActivityRepository(this._client);
  final ApiClient _client;

  Future<List<ProjectEvent>> events(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/${Uri.encodeComponent(projectId)}/events');
    return (json['events'] as List? ?? const []).cast<Map<String, dynamic>>().map(ProjectEvent.fromJson).toList();
  }
}
