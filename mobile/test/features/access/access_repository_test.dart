import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/access/data/access_repository.dart';
import 'package:arvend/features/access/domain/access_models.dart';
import 'package:arvend/features/auth/domain/user.dart';

import '../../test_utils/fake_api_client.dart';

/// AccessRepository'nin backend sözleşmesi (router.go /users,
/// /organization/roles, /organization/permissions): yol, gövde, sorgu ve
/// yanıt ayrıştırma. Ağ yok -- betikli sahte HTTP adaptörü.
Map<String, dynamic> _userJson(String id, {String role = 'kullanici', String orgRole = 'field', bool active = true}) =>
    {
      'id': id,
      'organization_id': 'org-1',
      'username': 'kullanici.$id',
      'full_name': 'Kişi $id',
      'role': role,
      'is_active': active,
      'must_change_password': false,
      'organization_role_code': orgRole,
      'organization_role_name': orgRole == 'owner' ? 'Sahip (Owner)' : 'Saha',
    };

Future<(AccessRepository, FakeHttpClientAdapter)> _repo(Map<String, List<ScriptedResponse>> script) async {
  final adapter = FakeHttpClientAdapter(script: script);
  return (AccessRepository(await buildFakeApiClient(adapter)), adapter);
}

void main() {
  group('kullanıcılar', () {
    test('listUsers tüm sayfaları 200lük sayfalarla toplar', () async {
      final page1 = [for (var i = 0; i < 200; i++) _userJson('a$i')];
      final page2 = [for (var i = 0; i < 12; i++) _userJson('b$i')];
      final (repo, adapter) = await _repo({
        '/users': [
          (status: 200, body: {'users': page1, 'total': 212}),
          (status: 200, body: {'users': page2, 'total': 212}),
        ],
      });

      final users = await repo.listUsers();

      expect(users.length, 212);
      expect(adapter.calls, ['/users', '/users']);
      expect(adapter.requestQueries[0], {'page': 1, 'limit': 200});
      expect(adapter.requestQueries[1], {'page': 2, 'limit': 200});
      expect(users.first.roleLabel, 'Saha');
    });

    test('tek sayfa yeterse ikinci istek atılmaz', () async {
      final (repo, adapter) = await _repo({
        '/users': [
          (
            status: 200,
            body: {
              'users': [_userJson('x', role: 'admin', orgRole: 'owner')],
              'total': 1,
            },
          ),
        ],
      });
      final users = await repo.listUsers();
      expect(adapter.calls, ['/users']);
      expect(users.single.role, UserRole.admin);
      expect(users.single.isOwnerOrAdmin, isTrue);
      expect(users.single.organizationRoleName, 'Sahip (Owner)');
    });

    test('rol adı yoksa kaba role düşer (web ile aynı)', () {
      final u = OrgUser.fromJson({'id': '1', 'username': 'a', 'full_name': 'A', 'role': 'admin', 'is_active': true});
      expect(u.roleLabel, 'Yönetici');
      final k = OrgUser.fromJson({
        'id': '2',
        'username': 'b',
        'full_name': 'B',
        'role': 'kullanici',
        'is_active': false,
      });
      expect(k.roleLabel, 'Kullanıcı');
      expect(k.isActive, isFalse);
    });

    test('createUser organizasyon rolünü ZORUNLU gönderir', () async {
      final (repo, adapter) = await _repo({
        '/users': [(status: 201, body: _userJson('new'))],
      });
      final created = await repo.createUser(
        username: 'yeni.kisi',
        password: 'gizli-sifre-1',
        fullName: 'Yeni Kişi',
        organizationRoleCode: 'field',
      );
      expect(created.id, 'new');
      expect(adapter.requestBodies.single, {
        'username': 'yeni.kisi',
        'password': 'gizli-sifre-1',
        'full_name': 'Yeni Kişi',
        'organization_role_code': 'field',
      });
    });

    test('getUser / updateUser / resetPassword / setOrganizationRole yolları ve gövdeleri', () async {
      final (repo, adapter) = await _repo({
        '/users/u1': [(status: 200, body: _userJson('u1')), (status: 200, body: _userJson('u1', active: false))],
        '/users/u1/password': [
          (status: 200, body: {'ok': true}),
        ],
        '/users/u1/organization-role': [
          (status: 200, body: {'ok': true}),
        ],
      });

      expect((await repo.getUser('u1')).fullName, 'Kişi u1');
      final updated = await repo.updateUser('u1', fullName: 'Yeni Ad', isActive: false);
      expect(updated.isActive, isFalse);
      await repo.resetPassword('u1', 'yepyeni-sifre');
      await repo.setOrganizationRole('u1', 'finance');

      expect(adapter.calls, ['/users/u1', '/users/u1', '/users/u1/password', '/users/u1/organization-role']);
      expect(adapter.requestBodies[1], {'full_name': 'Yeni Ad', 'is_active': false});
      expect(adapter.requestBodies[2], {'new_password': 'yepyeni-sifre'});
      expect(adapter.requestBodies[3], {'role_code': 'finance'});
    });

    test('kişiye özel yetkiler okunur ve sıralı liste olarak yazılır', () async {
      final detailJson = {
        'role_code': 'project_manager',
        'role_name': 'Proje Yöneticisi',
        'role_permissions': ['projects.read', 'attendance.manage'],
        'permissions': ['projects.read', 'offers.create'],
        'granted': ['offers.create'],
        'revoked': ['attendance.manage'],
        'editable': true,
      };
      final (repo, adapter) = await _repo({
        '/users/u1/permissions': [(status: 200, body: detailJson), (status: 200, body: detailJson)],
      });

      final detail = await repo.getUserPermissions('u1');
      expect(detail.roleCode, 'project_manager');
      expect(detail.granted, ['offers.create']);
      expect(detail.revoked, ['attendance.manage']);
      expect(detail.editable, isTrue);

      await repo.setUserPermissions('u1', {'projects.read', 'offers.create', 'customers.read'});
      expect(adapter.requestBodies[1], {
        'permissions': ['customers.read', 'offers.create', 'projects.read'],
      });
    });

    test('Sahip detayı düzenlenemez; editable alanı yoksa güvenli tarafta kalınır', () {
      final d = UserPermissionDetail.fromJson({'role_code': 'owner', 'role_name': 'Sahip'});
      expect(d.editable, isFalse);
      expect(d.permissions, isEmpty);
    });

    test('userProjects proje rolünü Türkçe etiketler', () async {
      final (repo, _) = await _repo({
        '/users/u1/projects': [
          (
            status: 200,
            body: {
              'projects': [
                {'project_id': 'p1', 'project_no': 'PRJ-1', 'project_name': 'Konut', 'project_role': 'viewer'},
              ],
            },
          ),
        ],
      });
      final projects = await repo.userProjects('u1');
      expect(projects.single.projectRoleLabel, 'Görüntüleyici');
    });

    test('403 ApiException(forbidden) olarak yükselir', () async {
      final (repo, _) = await _repo({
        '/users': [
          (status: 403, body: {'error': 'bu işlem için yetkiniz yok'}),
        ],
      });
      await expectLater(
        repo.listUsers(),
        throwsA(isA<ApiException>().having((e) => e.isForbidden, 'isForbidden', isTrue)),
      );
    });
  });

  group('roller', () {
    test('roller, katalog ve rol izinlerinin yazılması', () async {
      final (repo, adapter) = await _repo({
        '/organization/roles': [
          (
            status: 200,
            body: {
              'roles': [
                {
                  'id': 'r1',
                  'code': 'owner',
                  'name': 'Sahip (Owner)',
                  'description': 'Tüm izinler',
                  'is_system': true,
                  'permissions': ['projects.read'],
                },
              ],
            },
          ),
        ],
        '/organization/permissions': [
          (
            status: 200,
            body: {
              'permissions': [
                {'code': 'projects.read', 'description': 'Projeleri görüntüleme', 'category': 'Projeler'},
              ],
            },
          ),
        ],
        '/organization/roles/r2/permissions': [
          (
            status: 200,
            body: {
              'id': 'r2',
              'code': 'field',
              'name': 'Saha',
              'permissions': ['attendance.read', 'projects.read'],
            },
          ),
        ],
      });

      final roles = await repo.roles();
      expect(roles.single.isOwner, isTrue);
      expect(roles.single.permissions, ['projects.read']);

      final catalog = await repo.permissionCatalog();
      expect(catalog.single.category, 'Projeler');

      final saved = await repo.setRolePermissions('r2', {'projects.read', 'attendance.read'});
      expect(saved.permissions, ['attendance.read', 'projects.read']);
      expect(adapter.requestBodies.last, {
        'permissions': ['attendance.read', 'projects.read'],
      });
    });
  });
}
