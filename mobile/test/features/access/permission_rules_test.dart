import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/auth/permissions.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/features/access/data/access_repository.dart';
import 'package:arvend/features/access/domain/access_models.dart';
import 'package:arvend/features/access/domain/permission_rules.dart';
import 'package:arvend/features/access/domain/tr_text.dart';

import 'access_test_support.dart';

/// Web `lib/permissions.test.mts` ile aynı kurallar: yazma izni görüntülemeyi
/// açar, görüntüleme kapanınca bağlı yazma izinleri kapanır; rol + kişiye
/// özel yetki kaydı sırası; mevcut (listede olmayan) rolün korunması.
void main() {
  final catalog = kAllCodes;

  group('togglePermission', () {
    test('yazma izni açılınca aynı kaynağın görüntüleme izni de açılır', () {
      final next = togglePermission({}, 'offers.create', catalog);
      expect(next, {'offers.create', 'offers.read'});
    });

    test('görüntüleme kapanınca bağlı yazma izinleri kapanır, başka kaynaklar kalır', () {
      final next = togglePermission(
        {'offers.read', 'offers.create', 'offers.update', 'customers.read'},
        'offers.read',
        catalog,
      );
      expect(next, {'customers.read'});
    });

    test('iç içe kaynak: projects.finance.manage yalnızca projects.finance.read açar', () {
      final next = togglePermission({}, 'projects.finance.manage', catalog);
      expect(next, {'projects.finance.manage', 'projects.finance.read'});
    });

    test('projects.read kapanınca projects.create/update kapanır ama alt kaynaklar etkilenmez', () {
      final next = togglePermission(
        {'projects.read', 'projects.create', 'projects.finance.read'},
        'projects.read',
        catalog,
      );
      expect(next, {'projects.finance.read'});
    });

    test('katalogda görüntüleme kardeşi olmayan izin tek başına açılır', () {
      expect(readSiblingOf('offers.read', catalog), isNull);
      expect(readSiblingOf('bilinmeyen.manage', catalog), isNull);
    });
  });

  group('setPermissions', () {
    test('kategoriyi toplu açar ve kapatır (aynı tutarlılık kuralıyla)', () {
      final codes = ['offers.read', 'offers.create', 'offers.delete'];
      final on = setPermissions({'customers.read'}, codes, true, catalog);
      expect(on, {'customers.read', 'offers.read', 'offers.create', 'offers.delete'});
      final off = setPermissions({...on, 'offers.update'}, codes, false, catalog);
      // offers.read kapanınca bağlı offers.update de kapanır.
      expect(off, {'customers.read'});
    });
  });

  group('rol yardımcıları', () {
    test('orgRoleIsAdmin yalnızca owner/admin', () {
      expect(orgRoleIsAdmin('owner'), isTrue);
      expect(orgRoleIsAdmin('admin'), isTrue);
      expect(orgRoleIsAdmin('project_manager'), isFalse);
      expect(orgRoleIsAdmin(''), isFalse);
    });

    test('Yönetici-kilitli izinler yalnızca admin olmayan rollerde kilitli', () {
      expect(isAdminRoleOnlyFor('finance', 'organization.users.read'), isTrue);
      expect(isAdminRoleOnlyFor('admin', 'organization.users.read'), isFalse);
      expect(isAdminRoleOnlyFor('finance', 'offers.read'), isFalse);
      expect(kAdminRoleOnlyPermissions, contains('organization.settings.manage'));
    });

    test('rolesWithCurrent listede olmayan mevcut rolü "(mevcut rol)" ile ekler', () {
      final roles = sampleRoles();
      final legacy = sampleDetails()['u-legacy']!;
      final withCurrent = rolesWithCurrent(roles, legacy);
      expect(withCurrent.length, roles.length + 1);
      expect(withCurrent.last.code, 'legacy_user');
      expect(withCurrent.last.name, 'Kullanıcı (Eski Sistem) (mevcut rol)');
      expect(withCurrent.last.permissions, legacy.rolePermissions);
      // Zaten listede olan rol eklenmez; detay yoksa liste aynen döner.
      expect(rolesWithCurrent(roles, sampleDetails()['u-pm']), same(roles));
      expect(rolesWithCurrent(roles, null), same(roles));
    });

    test('sameSet sıra bağımsız', () {
      expect(sameSet({'a', 'b'}, {'b', 'a'}), isTrue);
      expect(sameSet({'a'}, {'a', 'b'}), isFalse);
    });

    test('groupByCategory backend sırasını korur', () {
      final groups = groupByCategory(kCatalog);
      expect(groups.first.$1, 'Projeler');
      expect(groups.map((g) => g.$1), containsAllInOrder(['Projeler', 'Finans', 'Görevler', 'Firma Yönetimi']));
      expect(groups.firstWhere((g) => g.$1 == 'Teklifler').$2.length, 5);
    });

    test('diffCount rolden farklı kutucukları sayar', () {
      expect(diffCount({'a', 'c'}, {'a', 'b'}, {'a', 'b', 'c'}), 2);
    });
  });

  group('saveUserAccess', () {
    test('rol değiştiyse ÖNCE rol, SONRA kişiye özel izinler yazılır', () async {
      final repo = FakeAccessRepository();
      await saveUserAccess(
        repo,
        'u-pm',
        'project_manager',
        const AccessState(roleCode: 'finance', selected: {'projects.read'}),
      );
      expect(repo.calls, ['setOrganizationRole u-pm finance', 'setUserPermissions u-pm']);
      expect(repo.lastUserPermissions, {'projects.read'});
    });

    test('rol aynıysa yalnızca izinler yazılır', () async {
      final repo = FakeAccessRepository();
      await saveUserAccess(
        repo,
        'u-pm',
        'project_manager',
        const AccessState(roleCode: 'project_manager', selected: {}),
      );
      expect(repo.calls, ['setUserPermissions u-pm']);
    });

    test("Sahip'e kişiye özel izin yazılmaz", () async {
      final repo = FakeAccessRepository();
      await saveUserAccess(repo, 'u-admin', 'admin', AccessState(roleCode: kOwnerRoleCode, selected: kAllCodes));
      expect(repo.calls, ['setOrganizationRole u-admin owner']);
    });

    test('rol yazılıp izinler başarısız olursa "yarım kayıt" hatası yeni rolü taşır', () async {
      final repo = FakeAccessRepository()..failNext['setUserPermissions'] = mapHttpError(500, 'izinler yazılamadı');
      final error = await saveUserAccess(
        repo,
        'u-pm',
        'project_manager',
        const AccessState(roleCode: 'finance', selected: {'projects.read'}),
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<UserAccessPartialSaveException>());
      final partial = error! as UserAccessPartialSaveException;
      expect(partial.savedRoleCode, 'finance');
      expect(partial.message, 'izinler yazılamadı');
      // Hâlâ ApiException: yalnızca ApiException yakalayan çağıranlar da çalışır.
      expect(partial, isA<ApiException>());
    });

    test('rol değişmediyse izin hatası olduğu gibi (yarım kayıt değil) fırlar', () async {
      final repo = FakeAccessRepository()..failNext['setUserPermissions'] = mapHttpError(409, 'çakışma');
      final error = await saveUserAccess(
        repo,
        'u-pm',
        'project_manager',
        const AccessState(roleCode: 'project_manager', selected: {}),
      ).then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<ApiException>());
      expect(error, isNot(isA<UserAccessPartialSaveException>()));
    });
  });

  group('modeller', () {
    test('OrgUser.roleLabel organizasyon rolü yoksa kaba role düşer', () {
      final u = OrgUser.fromJson({'id': 'x', 'username': 'a', 'full_name': 'A', 'role': 'admin', 'is_active': true});
      expect(u.roleLabel, 'Yönetici');
      expect(u.isOwnerOrAdmin, isFalse);
    });

    test('UserPermissionDetail JSON', () {
      final d = UserPermissionDetail.fromJson({
        'role_code': 'finance',
        'role_name': 'Finans',
        'role_permissions': ['projects.read'],
        'permissions': ['projects.read', 'offers.read'],
        'granted': ['offers.read'],
        'revoked': [],
        'editable': true,
      });
      expect(d.granted, ['offers.read']);
      expect(d.editable, isTrue);
    });

    test('Türkçe büyük/küçük harf', () {
      expect(trUpper('Firma Yönetimi'), 'FİRMA YÖNETİMİ');
      expect(searchKey('IŞIK'), searchKey('ışık'));
      expect(searchKey('İsmail'), 'ismail');
    });
  });
}
