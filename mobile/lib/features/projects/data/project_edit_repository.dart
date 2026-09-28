import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_providers.dart';
import '../domain/project_edit.dart';

/// Proje bilgilerini düzenleme uçları: `GET /projects/{id}` (projects.read)
/// ve `PUT /projects/{id}` (projects.update + proje üyeliği).
class ProjectEditRepository {
  ProjectEditRepository(this._client);
  final ApiClient _client;

  Future<ProjectEditable> load(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId');
    return ProjectEditable.fromJson(json);
  }

  Future<ProjectEditable> update(String projectId, ProjectEditInput input) async {
    final json = await _client.put<Map<String, dynamic>>('/projects/$projectId', data: input.toJson());
    return ProjectEditable.fromJson(json);
  }
}

final projectEditRepositoryProvider =
    Provider<ProjectEditRepository>((ref) => ProjectEditRepository(ref.watch(apiClientProvider)));

final projectEditableProvider = FutureProvider.autoDispose.family<ProjectEditable, String>(
  (ref, projectId) => ref.watch(projectEditRepositoryProvider).load(projectId),
);
