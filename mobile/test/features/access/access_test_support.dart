import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/access/access_routes.dart';
import 'package:arvend/features/access/data/access_providers.dart';
import 'package:arvend/features/access/data/access_repository.dart';
import 'package:arvend/features/access/domain/access_models.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/employees/data/employees_providers.dart';
import 'package:arvend/features/employees/data/employees_repository.dart';
import 'package:arvend/features/employees/domain/employee_record.dart';
import 'package:arvend/features/employees/employees_routes.dart';

import '../../test_utils/fake_api_client.dart';

/// Personel + Kullanıcılar + Roller & Yetkiler testlerinin ortak verisi,
/// sahte repository'leri ve uygulama kabuğu. Ağ YOK: repository'ler
/// bellek içi sahtelerle değiştirilir, ApiClient betiksiz sahte adaptörle
/// kurulur (beklenmeyen bir istek testi düşürür).

// ---------------------------------------------------------------------------
// İzin kataloğu (backend migration 0034 ile aynı kodlar/açıklamalar)
// ---------------------------------------------------------------------------

const kCatalog = <PermissionDef>[
  PermissionDef(code: 'projects.read', description: 'Projeleri görüntüleme', category: 'Projeler'),
  PermissionDef(code: 'projects.create', description: 'Yeni proje oluşturma', category: 'Projeler'),
  PermissionDef(code: 'projects.update', description: 'Proje bilgilerini düzenleme', category: 'Projeler'),
  PermissionDef(
    code: 'projects.finance.read',
    description: 'Proje finansal verilerini görüntüleme',
    category: 'Finans',
  ),
  PermissionDef(code: 'projects.finance.manage', description: 'Proje finansal işlemlerini yönetme', category: 'Finans'),
  PermissionDef(code: 'projects.tasks.read', description: 'Görevleri görüntüleme', category: 'Görevler'),
  PermissionDef(code: 'projects.tasks.create', description: 'Görev oluşturma', category: 'Görevler'),
  PermissionDef(code: 'projects.tasks.update', description: 'Görev düzenleme/tamamlama', category: 'Görevler'),
  PermissionDef(
    code: 'projects.operations.read',
    description: 'Planlama/dosya/fotoğraf/not/ekip görüntüleme',
    category: 'Operasyon',
  ),
  PermissionDef(
    code: 'projects.operations.manage',
    description: 'Planlama/dosya/fotoğraf/not/ekip yönetme',
    category: 'Operasyon',
  ),
  PermissionDef(code: 'offers.read', description: 'Teklifleri görüntüleme', category: 'Teklifler'),
  PermissionDef(code: 'offers.create', description: 'Teklif oluşturma', category: 'Teklifler'),
  PermissionDef(code: 'offers.update', description: 'Teklif düzenleme/revize etme/paylaşma', category: 'Teklifler'),
  PermissionDef(code: 'offers.approve', description: 'Teklif durumunu değiştirme', category: 'Teklifler'),
  PermissionDef(code: 'offers.delete', description: 'Teklif silme', category: 'Teklifler'),
  PermissionDef(code: 'customers.read', description: 'Müşterileri görüntüleme', category: 'Müşteriler'),
  PermissionDef(code: 'customers.manage', description: 'Müşterileri düzenleme', category: 'Müşteriler'),
  PermissionDef(code: 'employees.read', description: 'Personeli görüntüleme', category: 'Personel'),
  PermissionDef(code: 'employees.manage', description: 'Personeli düzenleme', category: 'Personel'),
  PermissionDef(code: 'attendance.read', description: 'Puantajı görüntüleme', category: 'Puantaj'),
  PermissionDef(code: 'attendance.manage', description: 'Puantaj kaydı girme/düzenleme', category: 'Puantaj'),
  PermissionDef(code: 'organization.users.read', description: 'Kullanıcıları görüntüleme', category: 'Firma Yönetimi'),
  PermissionDef(code: 'organization.users.manage', description: 'Kullanıcıları düzenleme', category: 'Firma Yönetimi'),
  PermissionDef(code: 'organization.roles.read', description: 'Rolleri görüntüleme', category: 'Firma Yönetimi'),
  PermissionDef(
    code: 'organization.roles.manage',
    description: 'Rolleri ve izinlerini düzenleme',
    category: 'Firma Yönetimi',
  ),
];

final Set<String> kAllCodes = {for (final p in kCatalog) p.code};

const _pmPerms = [
  'projects.read',
  'projects.update',
  'projects.tasks.read',
  'projects.tasks.create',
  'projects.tasks.update',
  'projects.operations.read',
  'projects.operations.manage',
  'offers.read',
  'customers.read',
  'employees.read',
  'attendance.read',
  'attendance.manage',
];

const _financePerms = [
  'projects.read',
  'projects.finance.read',
  'projects.finance.manage',
  'offers.read',
  'customers.read',
];

const _fieldPerms = [
  'projects.read',
  'projects.tasks.read',
  'projects.tasks.update',
  'projects.operations.read',
  'projects.operations.manage',
  'attendance.read',
];

List<OrganizationRole> sampleRoles() => [
  OrganizationRole(
    id: 'r-owner',
    code: 'owner',
    name: 'Sahip (Owner)',
    description: 'Firmadaki tüm izinlere sahiptir; son sahip kaldırılamaz.',
    permissions: [...kAllCodes],
  ),
  OrganizationRole(
    id: 'r-admin',
    code: 'admin',
    name: 'Yönetici',
    description: 'Firmadaki tüm izinlere sahiptir.',
    permissions: [...kAllCodes],
  ),
  const OrganizationRole(
    id: 'r-pm',
    code: 'project_manager',
    name: 'Proje Yöneticisi',
    description: 'Yalnızca atandığı projelerde operasyonel yönetim yapar.',
    permissions: _pmPerms,
  ),
  const OrganizationRole(
    id: 'r-finance',
    code: 'finance',
    name: 'Finans',
    description: 'Yalnızca atandığı projelerin finansal verilerini yönetir.',
    permissions: _financePerms,
  ),
  const OrganizationRole(
    id: 'r-field',
    code: 'field',
    name: 'Saha',
    description: 'Yalnızca atandığı projelerde saha operasyonu (görev/dosya/fotoğraf) yapar.',
    permissions: _fieldPerms,
  ),
];

List<OrgUser> sampleUsers() => const [
  OrgUser(
    id: 'u-owner',
    username: 'kemal.arslan',
    fullName: 'Kemal Arslan',
    role: UserRole.admin,
    isActive: true,
    organizationRoleCode: 'owner',
    organizationRoleName: 'Sahip (Owner)',
  ),
  OrgUser(
    id: 'u-admin',
    username: 'zeynep.koc',
    fullName: 'Zeynep Koç',
    role: UserRole.admin,
    isActive: true,
    organizationRoleCode: 'admin',
    organizationRoleName: 'Yönetici',
  ),
  OrgUser(
    id: 'u-pm',
    username: 'mehmet.demir',
    fullName: 'Mehmet Demir',
    role: UserRole.kullanici,
    isActive: true,
    organizationRoleCode: 'project_manager',
    organizationRoleName: 'Proje Yöneticisi',
  ),
  OrgUser(
    id: 'u-fin',
    username: 'ayse.kaya',
    fullName: 'Ayşe Kaya',
    role: UserRole.kullanici,
    isActive: true,
    organizationRoleCode: 'finance',
    organizationRoleName: 'Finans',
  ),
  OrgUser(
    id: 'u-field',
    username: 'ali.ozturk',
    fullName: 'Ali Öztürk',
    role: UserRole.kullanici,
    isActive: false,
    organizationRoleCode: 'field',
    organizationRoleName: 'Saha',
  ),
  OrgUser(
    id: 'u-legacy',
    username: 'hasan.aydin',
    fullName: 'Hasan Aydın',
    role: UserRole.kullanici,
    isActive: true,
    organizationRoleCode: 'legacy_user',
    organizationRoleName: 'Kullanıcı (Eski Sistem)',
  ),
];

/// Kişiye özel ayarlar: Mehmet'e rolünün dışında "Teklif oluşturma"
/// verilmiş, "Puantaj kaydı girme" alınmış.
Map<String, UserPermissionDetail> sampleDetails() => {
  'u-owner': UserPermissionDetail(
    roleCode: 'owner',
    roleName: 'Sahip (Owner)',
    rolePermissions: [...kAllCodes],
    permissions: [...kAllCodes],
    editable: false,
  ),
  'u-admin': UserPermissionDetail(
    roleCode: 'admin',
    roleName: 'Yönetici',
    rolePermissions: [...kAllCodes],
    permissions: [...kAllCodes],
  ),
  'u-pm': UserPermissionDetail(
    roleCode: 'project_manager',
    roleName: 'Proje Yöneticisi',
    rolePermissions: _pmPerms,
    permissions: [..._pmPerms.where((c) => c != 'attendance.manage'), 'offers.create'],
    granted: const ['offers.create'],
    revoked: const ['attendance.manage'],
  ),
  'u-fin': const UserPermissionDetail(
    roleCode: 'finance',
    roleName: 'Finans',
    rolePermissions: _financePerms,
    permissions: _financePerms,
  ),
  'u-field': const UserPermissionDetail(
    roleCode: 'field',
    roleName: 'Saha',
    rolePermissions: _fieldPerms,
    permissions: _fieldPerms,
  ),
  'u-legacy': const UserPermissionDetail(
    roleCode: 'legacy_user',
    roleName: 'Kullanıcı (Eski Sistem)',
    rolePermissions: ['projects.read', 'offers.read', 'customers.read'],
    permissions: ['projects.read', 'offers.read', 'customers.read'],
  ),
};

List<EmployeeRecord> sampleEmployees() => const [
  EmployeeRecord(
    id: 'e1',
    fullName: 'Mehmet Demir',
    phone: '0532 111 22 33',
    position: 'Şantiye Şefi',
    salary: 85000,
    startDate: '2024-03-01',
    description: 'Kadıköy konut projesinin saha sorumlusu.',
    userId: 'u-pm',
  ),
  EmployeeRecord(
    id: 'e2',
    fullName: 'Ahmet Yılmaz',
    phone: '0533 444 55 66',
    position: 'Kalıpçı Ustası',
    dailyWage: 2500,
    startDate: '2025-05-12',
  ),
  EmployeeRecord(id: 'e3', fullName: 'Fatma Şahin', position: 'Teknik Ofis', salary: 62000),
  EmployeeRecord(id: 'e5', fullName: 'Ayşe Kaya', position: 'Muhasebe', salary: 70000, userId: 'u-fin'),
  EmployeeRecord(id: 'e4', fullName: 'İsmail Çelik', position: 'Demirci', dailyWage: 2200, isActive: false),
];

// ---------------------------------------------------------------------------
// Oturum personaları
// ---------------------------------------------------------------------------

/// Sahip: her şey.
final ownerUser = User(
  id: 'u-owner',
  organizationId: 'org-1',
  username: 'kemal.arslan',
  fullName: 'Kemal Arslan',
  role: UserRole.admin,
  isActive: true,
  mustChangePassword: false,
  onboardingCompleted: true,
  onboardingStep: 'completed',
  organizationRoleCode: 'owner',
  organizationRoleName: 'Sahip (Owner)',
  permissions: kAllCodes,
);

/// Yönetici ama yalnızca görüntüleme izinleri (kişiye özel daraltılmış).
const readOnlyAdminUser = User(
  id: 'u-admin',
  organizationId: 'org-1',
  username: 'zeynep.koc',
  fullName: 'Zeynep Koç',
  role: UserRole.admin,
  isActive: true,
  mustChangePassword: false,
  onboardingCompleted: true,
  onboardingStep: 'completed',
  organizationRoleCode: 'admin',
  organizationRoleName: 'Yönetici',
  permissions: {'projects.read', 'employees.read', 'organization.users.read', 'organization.roles.read'},
);

/// Saha kullanıcısı: mesai için personeli görür, ücret/yönetim yok.
const employeeViewerUser = User(
  id: 'u-field',
  organizationId: 'org-1',
  username: 'ali.ozturk',
  fullName: 'Ali Öztürk',
  role: UserRole.kullanici,
  isActive: true,
  mustChangePassword: false,
  onboardingCompleted: true,
  onboardingStep: 'completed',
  organizationRoleCode: 'field',
  organizationRoleName: 'Saha',
  permissions: {'projects.read', 'employees.read', 'attendance.read', 'attendance.manage'},
);

/// Kaba rolü kullanici olan ama kişiye özel olarak kullanıcı okuma + personel
/// düzenleme izni verilmiş biri -- canAccess kullanıcı izinlerini reddeder.
const nonAdminManagerUser = User(
  id: 'u-pm',
  organizationId: 'org-1',
  username: 'mehmet.demir',
  fullName: 'Mehmet Demir',
  role: UserRole.kullanici,
  isActive: true,
  mustChangePassword: false,
  onboardingCompleted: true,
  onboardingStep: 'completed',
  organizationRoleCode: 'project_manager',
  organizationRoleName: 'Proje Yöneticisi',
  permissions: {'projects.read', 'employees.read', 'employees.manage', 'organization.users.read'},
);

/// Yönetici, tüm izinler (kendi hesabını düzenleyebilen kişi).
final fullAdminUser = User(
  id: 'u-admin',
  organizationId: 'org-1',
  username: 'zeynep.koc',
  fullName: 'Zeynep Koç',
  role: UserRole.admin,
  isActive: true,
  mustChangePassword: false,
  onboardingCompleted: true,
  onboardingStep: 'completed',
  organizationRoleCode: 'admin',
  organizationRoleName: 'Yönetici',
  permissions: kAllCodes,
);

/// Yönetici; kullanıcıları görür/düzenler ama Roller izinleri yok --
/// rol/yetki bölümleri gizlenmeli, yeni kullanıcı formu açılmamalı.
const usersOnlyAdminUser = User(
  id: 'u-admin2',
  organizationId: 'org-1',
  username: 'deniz.er',
  fullName: 'Deniz Er',
  role: UserRole.admin,
  isActive: true,
  mustChangePassword: false,
  onboardingCompleted: true,
  onboardingStep: 'completed',
  organizationRoleCode: 'admin',
  organizationRoleName: 'Yönetici',
  permissions: {'employees.read', 'employees.manage', 'organization.users.read', 'organization.users.manage'},
);

/// İzin kümesi boş (eski oturum / rolsüz) -- KATI kontrol erişimi reddeder.
const emptyPermissionsUser = User(
  id: 'u-empty',
  organizationId: 'org-1',
  username: 'bos',
  fullName: 'Boş Yetki',
  role: UserRole.admin,
  isActive: true,
  mustChangePassword: false,
  onboardingCompleted: true,
  onboardingStep: 'completed',
);

/// Hiçbir yönetim izni yok.
const noAccessUser = User(
  id: 'u-x',
  organizationId: 'org-1',
  username: 'misafir',
  fullName: 'Misafir Kullanıcı',
  role: UserRole.kullanici,
  isActive: true,
  mustChangePassword: false,
  onboardingCompleted: true,
  onboardingStep: 'completed',
  organizationRoleCode: 'field',
  organizationRoleName: 'Saha',
  permissions: {'projects.read'},
);

class FakeAuth extends AuthController {
  FakeAuth(this._user);
  final User _user;
  int refreshCount = 0;

  @override
  Future<User?> build() async => _user;

  @override
  Future<void> refresh() async => refreshCount++;
}

ApiException forbidden() => mapHttpError(403, 'bu işlem için yetkiniz yok');
ApiException badRequest(String message) => mapHttpError(400, message);

// ---------------------------------------------------------------------------
// Sahte repository'ler
// ---------------------------------------------------------------------------

class FakeAccessRepository implements AccessRepository {
  FakeAccessRepository({
    List<OrgUser>? users,
    List<OrganizationRole>? roles,
    Map<String, UserPermissionDetail>? details,
    this.catalog = kCatalog,
  }) : users = users ?? sampleUsers(),
       roleList = roles ?? sampleRoles(),
       details = details ?? sampleDetails();

  List<OrgUser> users;
  List<OrganizationRole> roleList;
  Map<String, UserPermissionDetail> details;
  final List<PermissionDef> catalog;

  /// Çağrı günlüğü, ör. "setOrganizationRole u-pm finance".
  final List<String> calls = [];

  /// Bir sonraki çağrıda fırlatılacak hata (metot adı -> hata), tek sefer.
  final Map<String, ApiException> failNext = {};

  /// Her çağrıda fırlatılacak hata (ör. kalıcı 403).
  final Map<String, ApiException> failAlways = {};

  /// Metot adı -> bekletme: çağrı bu tamamlanana kadar sürer (ör. yetki
  /// kaydı ağda uzun sürerken ekranın davranışı).
  final Map<String, Completer<void>> hold = {};

  Future<void> _wait(String method) async {
    final gate = hold[method];
    if (gate != null) await gate.future;
  }

  Set<String>? lastUserPermissions;
  Set<String>? lastRolePermissions;
  String? lastPassword;
  ({String username, String password, String fullName, String roleCode})? lastCreated;

  void _maybeFail(String method) {
    final always = failAlways[method];
    if (always != null) throw always;
    final once = failNext.remove(method);
    if (once != null) throw once;
  }

  @override
  Future<List<OrgUser>> listUsers() async {
    calls.add('listUsers');
    _maybeFail('listUsers');
    return users;
  }

  @override
  Future<OrgUser> getUser(String id) async {
    calls.add('getUser $id');
    _maybeFail('getUser');
    return users.firstWhere((u) => u.id == id, orElse: () => throw mapHttpError(404, 'kullanıcı bulunamadı'));
  }

  @override
  Future<OrgUser> createUser({
    required String username,
    required String password,
    required String fullName,
    required String organizationRoleCode,
  }) async {
    calls.add('createUser $username $organizationRoleCode');
    lastCreated = (username: username, password: password, fullName: fullName, roleCode: organizationRoleCode);
    await _wait('createUser');
    _maybeFail('createUser');
    final role = roleList.firstWhere((r) => r.code == organizationRoleCode);
    final created = OrgUser(
      id: 'u-new-${users.length}',
      username: username,
      fullName: fullName,
      role: organizationRoleCode == 'owner' || organizationRoleCode == 'admin' ? UserRole.admin : UserRole.kullanici,
      isActive: true,
      organizationRoleCode: role.code,
      organizationRoleName: role.name,
    );
    users = [...users, created];
    details = {
      ...details,
      created.id: UserPermissionDetail(
        roleCode: role.code,
        roleName: role.name,
        rolePermissions: role.permissions,
        permissions: role.permissions,
        editable: role.code != 'owner',
      ),
    };
    return created;
  }

  @override
  Future<OrgUser> updateUser(String id, {required String fullName, required bool isActive}) async {
    calls.add('updateUser $id $fullName $isActive');
    await _wait('updateUser');
    _maybeFail('updateUser');
    final old = users.firstWhere((u) => u.id == id);
    final next = OrgUser(
      id: old.id,
      username: old.username,
      fullName: fullName,
      role: old.role,
      isActive: isActive,
      organizationRoleCode: old.organizationRoleCode,
      organizationRoleName: old.organizationRoleName,
    );
    users = [for (final u in users) u.id == id ? next : u];
    return next;
  }

  @override
  Future<void> resetPassword(String id, String newPassword) async {
    calls.add('resetPassword $id');
    lastPassword = newPassword;
    _maybeFail('resetPassword');
  }

  @override
  Future<void> setOrganizationRole(String id, String roleCode) async {
    calls.add('setOrganizationRole $id $roleCode');
    await _wait('setOrganizationRole');
    _maybeFail('setOrganizationRole');
    final role = roleList.firstWhere((r) => r.code == roleCode);
    details = {
      ...details,
      id: UserPermissionDetail(
        roleCode: role.code,
        roleName: role.name,
        rolePermissions: role.permissions,
        permissions: role.permissions,
        editable: role.code != 'owner',
      ),
    };
  }

  @override
  Future<UserPermissionDetail> getUserPermissions(String id) async {
    calls.add('getUserPermissions $id');
    await _wait('getUserPermissions');
    _maybeFail('getUserPermissions');
    return details[id] ?? const UserPermissionDetail(roleCode: '', roleName: '', editable: false);
  }

  @override
  Future<UserPermissionDetail> setUserPermissions(String id, Set<String> permissions) async {
    calls.add('setUserPermissions $id');
    lastUserPermissions = permissions;
    await _wait('setUserPermissions');
    _maybeFail('setUserPermissions');
    final d = details[id]!;
    final next = UserPermissionDetail(
      roleCode: d.roleCode,
      roleName: d.roleName,
      rolePermissions: d.rolePermissions,
      permissions: [...permissions],
      granted: [...permissions.where((p) => !d.rolePermissions.contains(p))],
      revoked: [...d.rolePermissions.where((p) => !permissions.contains(p))],
      editable: d.editable,
    );
    details = {...details, id: next};
    return next;
  }

  @override
  Future<List<UserProjectAssignment>> userProjects(String id) async {
    calls.add('userProjects $id');
    _maybeFail('userProjects');
    if (id == 'u-pm') {
      return const [
        UserProjectAssignment(
          projectId: 'p1',
          projectNo: 'PRJ-2026-004',
          projectName: 'Kadıköy Konut Projesi',
          projectRole: 'project_manager',
        ),
        UserProjectAssignment(
          projectId: 'p2',
          projectNo: 'PRJ-2026-007',
          projectName: 'Ataşehir Ofis Tadilatı',
          projectRole: 'member',
        ),
      ];
    }
    return const [];
  }

  @override
  Future<List<OrganizationRole>> roles() async {
    calls.add('roles');
    _maybeFail('roles');
    return roleList;
  }

  @override
  Future<List<PermissionDef>> permissionCatalog() async {
    calls.add('permissionCatalog');
    _maybeFail('permissionCatalog');
    return catalog;
  }

  @override
  Future<OrganizationRole> setRolePermissions(String roleId, Set<String> permissions) async {
    calls.add('setRolePermissions $roleId');
    lastRolePermissions = permissions;
    await _wait('setRolePermissions');
    _maybeFail('setRolePermissions');
    final old = roleList.firstWhere((r) => r.id == roleId);
    final next = OrganizationRole(
      id: old.id,
      code: old.code,
      name: old.name,
      description: old.description,
      permissions: [...permissions],
    );
    roleList = [for (final r in roleList) r.id == roleId ? next : r];
    return next;
  }
}

class FakeEmployeesRepository implements EmployeesRepository {
  FakeEmployeesRepository({List<EmployeeRecord>? employees}) : employees = employees ?? sampleEmployees();

  List<EmployeeRecord> employees;
  final List<String> calls = [];
  final Map<String, ApiException> failNext = {};
  final Map<String, ApiException> failAlways = {};
  final List<EmployeeInput> created = [];
  final List<({String id, EmployeeInput input})> updated = [];

  /// Metot adı -> bekletme (bkz. FakeAccessRepository.hold).
  final Map<String, Completer<void>> hold = {};

  Future<void> _wait(String method) async {
    final gate = hold[method];
    if (gate != null) await gate.future;
  }

  void _maybeFail(String method) {
    final always = failAlways[method];
    if (always != null) throw always;
    final once = failNext.remove(method);
    if (once != null) throw once;
  }

  EmployeeRecord _fromInput(String id, EmployeeInput input) => EmployeeRecord(
    id: id,
    fullName: input.fullName,
    phone: input.phone,
    position: input.position,
    dailyWage: input.dailyWage,
    salary: input.salary,
    startDate: input.startDate,
    description: input.description,
    isActive: input.isActive,
    userId: input.userId.isEmpty ? null : input.userId,
  );

  @override
  Future<List<EmployeeRecord>> list({String filter = ''}) async {
    calls.add('list $filter'.trim());
    _maybeFail('list');
    return switch (filter) {
      'aktif' => employees.where((e) => e.isActive).toList(),
      'pasif' => employees.where((e) => !e.isActive).toList(),
      _ => employees,
    };
  }

  @override
  Future<EmployeeRecord> get(String id) async {
    calls.add('get $id');
    _maybeFail('get');
    return employees.firstWhere((e) => e.id == id, orElse: () => throw mapHttpError(404, 'personel bulunamadı'));
  }

  @override
  Future<EmployeeRecord> create(EmployeeInput input) async {
    calls.add('create');
    created.add(input);
    await _wait('create');
    _maybeFail('create');
    final record = _fromInput('e-new-${employees.length}', input);
    employees = [...employees, record];
    return record;
  }

  @override
  Future<EmployeeRecord> update(String id, EmployeeInput input) async {
    calls.add('update $id');
    updated.add((id: id, input: input));
    await _wait('update');
    _maybeFail('update');
    final record = _fromInput(id, input);
    employees = [for (final e in employees) e.id == id ? record : e];
    return record;
  }

  @override
  Future<void> archive(String id) async {
    calls.add('archive $id');
    _maybeFail('archive');
    employees = [
      for (final e in employees)
        e.id == id
            ? EmployeeRecord(
                id: e.id,
                fullName: e.fullName,
                phone: e.phone,
                position: e.position,
                salary: e.salary,
                dailyWage: e.dailyWage,
                startDate: e.startDate,
                description: e.description,
                isActive: false,
                userId: e.userId,
              )
            : e,
    ];
  }
}

// ---------------------------------------------------------------------------
// Uygulama kabuğu
// ---------------------------------------------------------------------------

/// Ekran görüntülerinde metin gerçek fontla çizilsin (aksi halde Ahem
/// kutuları) -- dashboard golden testleriyle aynı yöntem.
Future<void> loadAppFonts() async {
  final manifest = json.decode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

/// Uygulama teması; AppBar başlığına ve ElevatedButton metnine aile adı
/// verilir (bkz. dashboard golden testi -- temadaki bu iki stil fontFamily
/// taşımadığı için test motorunda kutu glifine düşer; cihazda platform
/// yazı tipiyle çizilir).
ThemeData goldenTheme() {
  final theme = AppTheme.light();
  final elevated = theme.elevatedButtonTheme.style;
  final buttonText = elevated?.textStyle?.resolve(const <WidgetState>{});
  return theme.copyWith(
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Inter'),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: elevated?.copyWith(
        textStyle: WidgetStatePropertyAll((buttonText ?? const TextStyle()).copyWith(fontFamily: 'Inter')),
      ),
    ),
  );
}

Future<ApiClient> unscriptedClient() => buildFakeApiClient(FakeHttpClientAdapter(script: {}));

/// `/diger` altına Personel + Kullanıcılar + Roller rotalarını (entegrasyon
/// adımının yapacağı gibi) kaydeden bir uygulama.
Widget buildAccessApp({
  required ApiClient client,
  required User user,
  required String location,
  FakeAccessRepository? access,
  FakeEmployeesRepository? employees,
  FakeAuth? auth,
}) {
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/diger',
        builder: (_, _) => const Scaffold(body: Center(child: Text('DİĞER'))),
        routes: [...employeesRoutes, ...accessRoutes],
      ),
      GoRoute(
        path: '/projeler/:id',
        builder: (_, s) => Scaffold(body: Text('PROJE ${s.pathParameters['id']}')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(client),
      authControllerProvider.overrideWith(() => auth ?? FakeAuth(user)),
      accessRepositoryProvider.overrideWithValue(access ?? FakeAccessRepository()),
      employeesRepositoryProvider.overrideWithValue(employees ?? FakeEmployeesRepository()),
    ],
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: goldenTheme(),
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      routerConfig: router,
    ),
  );
}

// ---------------------------------------------------------------------------
// Ekran testleri için yardımcılar
// ---------------------------------------------------------------------------

/// Uzun detay/form ekranları az kaydırmayla test edilsin diye yüksek bir
/// yüzey (mantıksal 480x2400; test yazı tipi Ahem geniş çizer).
Future<void> pumpAccessApp(
  WidgetTester tester, {
  required ApiClient client,
  required User user,
  required String location,
  FakeAccessRepository? access,
  FakeEmployeesRepository? employees,
  FakeAuth? auth,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(480, 2400);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    buildAccessApp(client: client, user: user, location: location, access: access, employees: employees, auth: auth),
  );
  await tester.pumpAndSettle();
}

/// Sayfanın dikey kaydırıcısı (yatay filtre çubuğu hariç).
Finder get verticalScrollable =>
    find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).first;

/// Tembel kurulan liste öğesini görünür yapıp dokunur.
Future<void> scrollAndTap(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: verticalScrollable);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// "Tümünü Seç" / "Tümünü Kaldır" düğmeleri (kategori başlıklarında).
final Finder categoryActionButtons = find.byWidgetPredicate(
  (w) => w is TextButton && w.child is Text && const {'Tümünü Seç', 'Tümünü Kaldır'}.contains((w.child as Text).data),
);

/// Bir izin kategorisinin başlığındaki (aynı satırdaki) "Tümünü Seç/Kaldır"
/// düğmesi; yoksa hiçbir şey bulmayan bir bulucu.
Finder categoryAction(WidgetTester tester, String categoryUpper) {
  final y = tester.getCenter(find.textContaining(categoryUpper).first).dy;
  final elements = categoryActionButtons.evaluate().toList();
  for (var i = 0; i < elements.length; i++) {
    final box = elements[i].renderObject as RenderBox?;
    if (box == null || !box.attached) continue;
    if ((box.localToGlobal(box.size.center(Offset.zero)).dy - y).abs() < 20) return categoryActionButtons.at(i);
  }
  return find.byKey(const ValueKey('__kategori-dugmesi-yok__'));
}

/// Görünen tüm kutucukların salt-okunur olup olmadığı.
bool allCheckboxesDisabled(WidgetTester tester) =>
    tester.widgetList<Checkbox>(find.byType(Checkbox)).every((c) => c.onChanged == null);
