import '../../../core/auth/permissions.dart';
import 'access_models.dart';

/// Kişiye özel yetki düzenleyicisinin saf kuralları -- web
/// `lib/permissions.ts` (togglePermission/setPermissions/orgRoleIsAdmin) ve
/// `components/permissions/saveUserAccess.ts` (sameSet/rolesWithCurrent)
/// ile BİREBİR aynı davranış. Asıl sınır yine backend'dedir; bunlar
/// kişiyi çıkmaz kombinasyonlara (göremediği şeyi düzenleme) düşürmemek
/// içindir.

/// Kişinin rolü + seçili (etkin) izin kümesi -- web `AccessState`.
class AccessState {
  const AccessState({required this.roleCode, required this.selected});

  const AccessState.empty() : roleCode = '', selected = const {};

  final String roleCode;
  final Set<String> selected;

  AccessState copyWith({String? roleCode, Set<String>? selected}) =>
      AccessState(roleCode: roleCode ?? this.roleCode, selected: selected ?? this.selected);
}

/// Kaba rolü admin olan (Sahip/Yönetici) organizasyon rolleri --
/// backend `coarseRoleForOrgRole` ile aynı.
bool orgRoleIsAdmin(String roleCode) => roleCode == 'owner' || roleCode == 'admin';

/// Sahip/Yönetici dışındaki bir rolde işe yaramayan (backend kişiye özel
/// eklenmesini 400 ile reddeden) izin mi?
bool isAdminRoleOnlyFor(String roleCode, String permissionCode) =>
    !orgRoleIsAdmin(roleCode) && kAdminRoleOnlyPermissions.contains(permissionCode);

/// Bir yazma izninin (ör. offers.create) aynı kaynağın görüntüleme iznine
/// (offers.read) bağlı olduğu varsayılır: kaynak = kodun son noktaya
/// kadarki kısmı. Katalogda yoksa bağ yoktur.
String? readSiblingOf(String code, Set<String> catalog) {
  final dot = code.lastIndexOf('.');
  if (dot < 0) return null;
  final read = '${code.substring(0, dot)}.read';
  return read != code && catalog.contains(read) ? read : null;
}

/// Bir kutucuğu çevirir: yazma izni açılınca görüntüleme de açılır;
/// görüntüleme kapanınca ona bağlı yazma izinleri de kapanır.
Set<String> togglePermission(Set<String> selected, String code, Set<String> catalog) {
  final next = {...selected};
  if (next.contains(code)) {
    next.remove(code);
    for (final other in catalog) {
      if (readSiblingOf(other, catalog) == code) next.remove(other);
    }
  } else {
    next.add(code);
    final read = readSiblingOf(code, catalog);
    if (read != null) next.add(read);
  }
  return next;
}

/// Bir kategorinin kutucuklarını topluca açar/kapatır -- togglePermission
/// ile AYNI tutarlılık kuralı.
Set<String> setPermissions(Set<String> selected, Iterable<String> codes, bool on, Set<String> catalog) {
  var next = {...selected};
  for (final code in codes) {
    if (next.contains(code) != on) next = togglePermission(next, code, catalog);
  }
  return next;
}

bool sameSet(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

/// Atanabilir roller listesi "Eski Sistem" (legacy_user) rolünü içermez.
/// O roldeki bir kişinin rol kutusu listedeki ilk role düşmesin ve rolün
/// varsayılanlarına göre kişiye özel ayar yapılabilsin diye mevcut rol
/// "(mevcut rol)" etiketiyle seçenek olarak eklenir.
List<OrganizationRole> rolesWithCurrent(List<OrganizationRole> roles, UserPermissionDetail? detail) {
  if (detail == null || detail.roleCode.isEmpty || roles.any((r) => r.code == detail.roleCode)) return roles;
  final label = detail.roleName.isNotEmpty ? detail.roleName : detail.roleCode;
  return [
    ...roles,
    OrganizationRole(
      id: 'mevcut-${detail.roleCode}',
      code: detail.roleCode,
      name: '$label (mevcut rol)',
      permissions: detail.rolePermissions,
    ),
  ];
}

/// Kataloğu, backend'in döndüğü sırayı koruyarak kategorilere böler.
List<(String, List<PermissionDef>)> groupByCategory(List<PermissionDef> catalog) {
  final byCategory = <String, List<PermissionDef>>{};
  for (final p in catalog) {
    byCategory.putIfAbsent(p.category, () => []).add(p);
  }
  return [for (final e in byCategory.entries) (e.key, e.value)];
}

/// Rol varsayılanından farklı (kişiye özel) kutucuk sayısı.
int diffCount(Set<String> selected, Set<String> roleDefaults, Set<String> catalog) =>
    catalog.where((c) => selected.contains(c) != roleDefaults.contains(c)).length;
