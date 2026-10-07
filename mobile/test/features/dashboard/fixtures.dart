import 'dart:convert';
import 'dart:io';

import 'package:arvend/features/auth/domain/user.dart';

/// Ana sayfa sözleşme fixture'ları -- backend, web ve mobil testlerinin
/// ORTAK kaynağı (docs/dashboard/fixtures/*.json, spec §4.11/§6.8). flutter
/// test çalışma dizini `mobile/` olduğu için göreli yol `../docs/...`.
const kDashboardPersonas = ['owner', 'empty_company', 'field', 'finance'];

Map<String, dynamic> fixtureJson(String name) =>
    json.decode(File('../docs/dashboard/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// Backend'in tüm izin kodları (domain Perm* sabitleri) -- Sahip/Yönetici.
const kAllPermissions = <String>[
  'attendance.manage',
  'attendance.read',
  'calculations.manage',
  'calculations.read',
  'customers.manage',
  'customers.read',
  'employees.manage',
  'employees.read',
  'notifications.read',
  'offers.approve',
  'offers.create',
  'offers.delete',
  'offers.internal_pricing.manage',
  'offers.internal_pricing.read',
  'offers.read',
  'offers.update',
  'organization.cost_codes.manage',
  'organization.cost_codes.read',
  'organization.roles.manage',
  'organization.roles.read',
  'organization.settings.manage',
  'organization.settings.read',
  'organization.suppliers.manage',
  'organization.suppliers.read',
  'organization.users.manage',
  'organization.users.read',
  'products.manage',
  'products.read',
  'projects.access.manage',
  'projects.access.read',
  'projects.budget.manage',
  'projects.budget.read',
  'projects.contracts.lifecycle',
  'projects.contracts.manage',
  'projects.contracts.read',
  'projects.cost_control.manage',
  'projects.cost_control.read',
  'projects.create',
  'projects.expenses.approve',
  'projects.expenses.create',
  'projects.finance.manage',
  'projects.finance.read',
  'projects.operations.manage',
  'projects.operations.read',
  'projects.procurement.approve',
  'projects.procurement.manage',
  'projects.procurement.read',
  'projects.read',
  'projects.subcontract_claims.certify',
  'projects.subcontract_claims.manage',
  'projects.subcontract_claims.read',
  'projects.subcontract_payments.manage',
  'projects.subcontract_payments.read',
  'projects.subcontracts.approve',
  'projects.subcontracts.manage',
  'projects.subcontracts.read',
  'projects.tasks.create',
  'projects.tasks.read',
  'projects.tasks.update',
  'projects.update',
];

/// Saha rolünün varsayılan izinleri (spec §8.3; masraf girme backend
/// migration 0066 ile her role verildi).
const kFieldPermissions = <String>[
  'projects.expenses.create',
  'projects.read',
  'projects.tasks.read',
  'projects.tasks.update',
  'projects.operations.read',
  'projects.operations.manage',
  'attendance.read',
  'notifications.read',
];

/// Finans rolünün varsayılan izinleri (spec §8.4; 0066: masraf girer,
/// onaylamaz).
const kFinancePermissions = <String>[
  'projects.expenses.create',
  'projects.read',
  'projects.finance.read',
  'projects.finance.manage',
  'projects.budget.read',
  'projects.budget.manage',
  'projects.cost_control.read',
  'projects.cost_control.manage',
  'projects.contracts.read',
  'projects.contracts.manage',
  'projects.contracts.lifecycle',
  'projects.procurement.read',
  'projects.procurement.manage',
  'projects.procurement.approve',
  'projects.subcontracts.read',
  'projects.subcontracts.manage',
  'projects.subcontracts.approve',
  'projects.subcontract_claims.read',
  'projects.subcontract_claims.manage',
  'projects.subcontract_claims.certify',
  'projects.subcontract_payments.read',
  'projects.subcontract_payments.manage',
  'organization.cost_codes.read',
  'organization.cost_codes.manage',
  'organization.suppliers.read',
  'organization.suppliers.manage',
  'notifications.read',
];

User _user({
  required String id,
  required String fullName,
  required String organizationName,
  required UserRole role,
  required String roleCode,
  required String roleName,
  required List<String> permissions,
}) => User(
  id: id,
  organizationId: '0a000000-0000-4000-8000-000000000001',
  username: id,
  fullName: fullName,
  role: role,
  isActive: true,
  mustChangePassword: false,
  onboardingCompleted: true,
  onboardingStep: 'completed',
  organizationName: organizationName,
  organizationRoleCode: roleCode,
  organizationRoleName: roleName,
  permissions: permissions.toSet(),
);

final ownerUser = _user(
  id: '0c000000-0000-4000-8000-000000000001',
  fullName: 'Taha Eryetişözen',
  organizationName: 'Arvend Yapı',
  role: UserRole.admin,
  roleCode: 'owner',
  roleName: 'Sahip',
  permissions: kAllPermissions,
);

final emptyOwnerUser = _user(
  id: '0c000000-0000-4000-8000-000000000002',
  fullName: 'Deniz Kara',
  organizationName: 'Yeni Yapı Ltd.',
  role: UserRole.admin,
  roleCode: 'owner',
  roleName: 'Sahip',
  permissions: kAllPermissions,
);

final fieldUser = _user(
  id: '0c000000-0000-4000-8000-000000000003',
  fullName: 'Hasan Öz',
  organizationName: 'Arvend Yapı',
  role: UserRole.kullanici,
  roleCode: 'field',
  roleName: 'Saha',
  permissions: kFieldPermissions,
);

final financeUser = _user(
  id: '0c000000-0000-4000-8000-000000000004',
  fullName: 'Selin Arslan',
  organizationName: 'Arvend Yapı',
  role: UserRole.kullanici,
  roleCode: 'finance',
  roleName: 'Finans',
  permissions: kFinancePermissions,
);

User userFor(String persona) => switch (persona) {
  'owner' => ownerUser,
  'empty_company' => emptyOwnerUser,
  'field' => fieldUser,
  'finance' => financeUser,
  _ => throw ArgumentError('bilinmeyen persona: $persona'),
};
