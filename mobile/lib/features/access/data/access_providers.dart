import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/access_models.dart';
import 'access_repository.dart';

final accessRepositoryProvider = Provider<AccessRepository>((ref) => AccessRepository(ref.watch(apiClientProvider)));

/// Firmanın tüm kullanıcıları (organization.users.read).
final orgUsersProvider = FutureProvider.autoDispose<List<OrgUser>>(
  (ref) => ref.watch(accessRepositoryProvider).listUsers(),
);

final orgUserDetailProvider = FutureProvider.autoDispose.family<OrgUser, String>(
  (ref, id) => ref.watch(accessRepositoryProvider).getUser(id),
);

final userProjectsProvider = FutureProvider.autoDispose.family<List<UserProjectAssignment>, String>(
  (ref, id) => ref.watch(accessRepositoryProvider).userProjects(id),
);

/// Atanabilir organizasyon rolleri (organization.roles.read).
final organizationRolesProvider = FutureProvider.autoDispose<List<OrganizationRole>>(
  (ref) => ref.watch(accessRepositoryProvider).roles(),
);

/// İzin kataloğu (organization.roles.read).
final permissionCatalogProvider = FutureProvider.autoDispose<List<PermissionDef>>(
  (ref) => ref.watch(accessRepositoryProvider).permissionCatalog(),
);

typedef RoleCatalog = ({List<OrganizationRole> roles, List<PermissionDef> catalog});

/// Rol listesi + izin kataloğu birlikte (matris ve Roller ekranı ikisine
/// birden ihtiyaç duyar).
final roleCatalogProvider = FutureProvider.autoDispose<RoleCatalog>((ref) async {
  // Future.wait: hata olursa ASIL ApiException fırlar (record `.wait`'in
  // ParallelWaitError sarmalayıcısı 403 mesajını gizlerdi).
  final results = await Future.wait<Object>([
    ref.watch(organizationRolesProvider.future),
    ref.watch(permissionCatalogProvider.future),
  ]);
  return (roles: results[0] as List<OrganizationRole>, catalog: results[1] as List<PermissionDef>);
});

typedef UserAccessBundle = ({UserPermissionDetail detail, List<OrganizationRole> roles, List<PermissionDef> catalog});

/// Bir giriş hesabının rol + kişiye özel yetki düzenleyicisinin verisi.
final userAccessBundleProvider = FutureProvider.autoDispose.family<UserAccessBundle, String>((ref, userId) async {
  final results = await Future.wait<Object>([
    ref.watch(accessRepositoryProvider).getUserPermissions(userId),
    ref.watch(roleCatalogProvider.future),
  ]);
  final rc = results[1] as RoleCatalog;
  return (detail: results[0] as UserPermissionDetail, roles: rc.roles, catalog: rc.catalog);
});
