import '../../../core/api/api_client.dart';
import '../../../core/errors/api_exception.dart';
import '../domain/access_models.dart';
import '../domain/permission_rules.dart';

/// Kullanıcılar + Roller & Yetkiler + kişiye özel yetkiler. Uçların hepsi
/// backend'de izne EK OLARAK kaba `requireAdmin` ister (bkz. router.go
/// /users, /organization/roles, /organization/permissions) -- ekranlar
/// çağırmadan önce `canAccess` ile kontrol eder.
class AccessRepository {
  AccessRepository(this._client);
  final ApiClient _client;

  /// Backend sayfa başına en çok 200 döndürür (üstü sessizce 50'ye düşer);
  /// firmanın TÜM kullanıcılarını sayfa sayfa toplar -- personel ekranındaki
  /// "Bağlı Kullanıcı Hesabı" seçicisi de tam listeye ihtiyaç duyar.
  Future<List<OrgUser>> listUsers() async {
    const limit = 200;
    final all = <OrgUser>[];
    for (var page = 1; page <= 50; page++) {
      final json = await _client.get<Map<String, dynamic>>('/users', query: {'page': page, 'limit': limit});
      final batch = (json['users'] as List).cast<Map<String, dynamic>>().map(OrgUser.fromJson).toList();
      all.addAll(batch);
      final total = (json['total'] as num?)?.toInt() ?? all.length;
      if (batch.length < limit || all.length >= total) break;
    }
    return all;
  }

  Future<OrgUser> getUser(String id) async => OrgUser.fromJson(await _client.get<Map<String, dynamic>>('/users/$id'));

  /// `organization_role_code` ZORUNLU (backend 400 döner) -- yeni üye
  /// "Eski Sistem" rolüne düşmesin diye.
  ///
  /// Personel kaydı ("kişi = tek kayıt") hesapla aynı işlemde: [employeeId]
  /// verilirse o personele bağlanır; [createEmployee] false ise hiç
  /// dokunulmaz; aksi halde yeni kayıt açılır ya da aynı adlı TEK
  /// bağlantısız personele bağlanır ([linkSameName] false bunu kapatır).
  /// null alanlar GÖNDERİLMEZ -- backend varsayılanı uygular. Sonuç
  /// [OrgUser.employeeLink]'te.
  Future<OrgUser> createUser({
    required String username,
    required String password,
    required String fullName,
    required String organizationRoleCode,
    bool? createEmployee,
    String? employeeId,
    bool? linkSameName,
  }) async {
    final json = await _client.post<Map<String, dynamic>>(
      '/users',
      data: {
        'username': username,
        'password': password,
        'full_name': fullName,
        'organization_role_code': organizationRoleCode,
        'create_employee': ?createEmployee,
        'employee_id': ?employeeId,
        'link_same_name': ?linkSameName,
      },
    );
    return OrgUser.fromJson(json);
  }

  /// Ad soyad + aktiflik. Rol bu uçtan DEĞİŞMEZ ([setOrganizationRole]).
  /// Son aktif Sahip pasifleştirilemez (backend 409).
  Future<OrgUser> updateUser(String id, {required String fullName, required bool isActive}) async {
    final json = await _client.put<Map<String, dynamic>>(
      '/users/$id',
      data: {'full_name': fullName, 'is_active': isActive},
    );
    return OrgUser.fromJson(json);
  }

  Future<void> resetPassword(String id, String newPassword) =>
      _client.patch<dynamic>('/users/$id/password', data: {'new_password': newPassword});

  /// Rol değişince backend kişinin eski kişiye özel ayarlarını sıfırlar.
  Future<void> setOrganizationRole(String id, String roleCode) =>
      _client.put<dynamic>('/users/$id/organization-role', data: {'role_code': roleCode});

  Future<UserPermissionDetail> getUserPermissions(String id) async =>
      UserPermissionDetail.fromJson(await _client.get<Map<String, dynamic>>('/users/$id/permissions'));

  /// Kişinin ETKİN izin kümesini verilen listeye eşitler; rolden farklı
  /// olanlar backend'de kişiye özel ayar olarak saklanır. Sahip'te 409.
  Future<UserPermissionDetail> setUserPermissions(String id, Set<String> permissions) async {
    final json = await _client.put<Map<String, dynamic>>(
      '/users/$id/permissions',
      data: {
        'permissions': [...permissions]..sort(),
      },
    );
    return UserPermissionDetail.fromJson(json);
  }

  Future<List<UserProjectAssignment>> userProjects(String id) async {
    final json = await _client.get<Map<String, dynamic>>('/users/$id/projects');
    return (json['projects'] as List).cast<Map<String, dynamic>>().map(UserProjectAssignment.fromJson).toList();
  }

  Future<List<OrganizationRole>> roles() async {
    final json = await _client.get<Map<String, dynamic>>('/organization/roles');
    return (json['roles'] as List).cast<Map<String, dynamic>>().map(OrganizationRole.fromJson).toList();
  }

  Future<List<PermissionDef>> permissionCatalog() async {
    final json = await _client.get<Map<String, dynamic>>('/organization/permissions');
    return (json['permissions'] as List).cast<Map<String, dynamic>>().map(PermissionDef.fromJson).toList();
  }

  /// Rolün izin kümesini TAMAMEN değiştirir -- o roldeki herkesi etkiler.
  Future<OrganizationRole> setRolePermissions(String roleId, Set<String> permissions) async {
    final json = await _client.put<Map<String, dynamic>>(
      '/organization/roles/$roleId/permissions',
      data: {
        'permissions': [...permissions]..sort(),
      },
    );
    return OrganizationRole.fromJson(json);
  }
}

/// [saveUserAccess]'in ikinci adımı (kişiye özel izinler) başarısız oldu
/// ama ROL DEĞİŞİMİ sunucuya yazıldı. Rol değişimi backend'de kişiye özel
/// ayarları da sıfırladığı için kişi artık yeni rolün varsayılanlarındadır;
/// ekran eski rolü "kayıtlı" sanmamalı. `ApiException`'dır -- yalnızca
/// `ApiException` yakalayan çağıranlar da aynen çalışır.
class UserAccessPartialSaveException extends ApiException {
  UserAccessPartialSaveException(ApiException cause, {required this.savedRoleCode})
    : super(statusCode: cause.statusCode, message: cause.message, kind: cause.kind);

  /// Sunucuya yazılan (artık geçerli) rol.
  final String savedRoleCode;
}

/// Önce rolü (değiştiyse), sonra kişiye özel izinleri kaydeder -- web
/// `saveUserAccess` ile aynı. Sıra önemli: backend rol değişiminde eski
/// kişiye özel ayarları sıfırlar, izinler yeni role göre fark olarak
/// yazılır. Sahip'e kişiye özel izin yazılmaz (backend reddeder).
///
/// Rol yazıldıktan sonra izinler başarısız olursa
/// [UserAccessPartialSaveException] fırlar.
Future<void> saveUserAccess(AccessRepository repo, String userId, String savedRoleCode, AccessState access) async {
  final roleChanged = access.roleCode != savedRoleCode;
  if (roleChanged) {
    await repo.setOrganizationRole(userId, access.roleCode);
  }
  if (access.roleCode != kOwnerRoleCode) {
    try {
      await repo.setUserPermissions(userId, access.selected);
    } on ApiException catch (e) {
      if (roleChanged) throw UserAccessPartialSaveException(e, savedRoleCode: access.roleCode);
      rethrow;
    }
  }
}
