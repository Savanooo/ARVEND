import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_providers.dart';
import '../domain/portal.dart';

/// Taşeron Paneli uçları (backend migration 0075):
/// - Taşeron: GET /portal/overview
/// - Firma (organization.users.*): /subcontractors/{id}/portal ...
///   GET (girişler + proje izinleri), POST users (giriş aç), POST
///   users/{uid}/password (geçici şifre), POST users/{uid}/active, PUT projects.
class PortalRepository {
  PortalRepository(this._client);
  final ApiClient _client;

  Future<PortalOverview> overview() async =>
      PortalOverview.fromJson(await _client.get<Map<String, dynamic>>('/portal/overview'));

  String _base(String supplierId) => '/subcontractors/${Uri.encodeComponent(supplierId)}/portal';

  Future<PortalSettings> settings(String supplierId) async =>
      PortalSettings.fromJson(await _client.get<Map<String, dynamic>>(_base(supplierId)));

  Future<PortalUser> createUser(
    String supplierId, {
    required String fullName,
    required String username,
    required String temporaryPassword,
  }) async =>
      PortalUser.fromJson(await _client.post<Map<String, dynamic>>('${_base(supplierId)}/users', data: {
        'full_name': fullName,
        'username': username,
        'temporary_password': temporaryPassword,
      }));

  Future<PortalUser> resetPassword(String supplierId, String userId, String temporaryPassword) async =>
      PortalUser.fromJson(await _client.post<Map<String, dynamic>>(
        '${_base(supplierId)}/users/${Uri.encodeComponent(userId)}/password',
        data: {'temporary_password': temporaryPassword},
      ));

  Future<PortalUser> setActive(String supplierId, String userId, bool active) async =>
      PortalUser.fromJson(await _client.post<Map<String, dynamic>>(
        '${_base(supplierId)}/users/${Uri.encodeComponent(userId)}/active',
        data: {'active': active},
      ));

  Future<PortalSettings> setProjects(String supplierId, List<String> projectIds) async =>
      PortalSettings.fromJson(await _client.put<Map<String, dynamic>>(
        '${_base(supplierId)}/projects',
        data: {'project_ids': projectIds},
      ));
}

final portalRepositoryProvider = Provider<PortalRepository>((ref) => PortalRepository(ref.watch(apiClientProvider)));

final portalOverviewProvider = FutureProvider.autoDispose<PortalOverview>(
  (ref) => ref.watch(portalRepositoryProvider).overview(),
);

final portalSettingsProvider = FutureProvider.autoDispose.family<PortalSettings, String>(
  (ref, supplierId) => ref.watch(portalRepositoryProvider).settings(supplierId),
);
