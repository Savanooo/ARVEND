import '../../../core/api/api_client.dart';
import '../domain/dashboard.dart';

/// Ana sayfa uçları (spec §4.1):
///   - GET /dashboard -- tek anlık görüntü; bölüm kapılarını sunucu uygular.
///   - GET /dashboard/project-options -- hızlı işlem proje seçicisi; para
///     alanı TAŞIMAZ (GET /projects bilinçli olarak kullanılmaz, D16).
class DashboardRepository {
  DashboardRepository(this._api);
  final ApiClient _api;

  Future<Dashboard> fetch() async => Dashboard.fromJson(await _api.get<Map<String, dynamic>>('/dashboard'));

  Future<List<ProjectOption>> projectOptions({String q = ''}) async {
    final query = q.trim();
    final res = await _api.get<Map<String, dynamic>>(
      '/dashboard/project-options',
      query: query.isEmpty ? null : {'q': query},
    );
    return [
      for (final e in (res['projects'] as List<dynamic>? ?? const []))
        ProjectOption.fromJson((e as Map).cast<String, dynamic>()),
    ];
  }
}
