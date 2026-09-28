import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../domain/access_models.dart';
import '../../domain/permission_rules.dart';
import 'permission_checklist.dart';

/// Kişinin rolü + o kişiye özel detaylı izinleri -- web
/// `components/permissions/PermissionMatrix` karşılığı. Rol başlangıç
/// noktasıdır: rol değişince kutucuklar o rolün varsayılanlarına döner
/// (backend de rol değişiminde kişiye özel ayarları sıfırlar). Rolden farklı
/// kutucuklar işaretlenir, böylece kişiye neyin özel verildiği tek bakışta
/// görünür. Kontrollü bileşendir: durumu çağıran tutar ([value]/[onChanged]).
class PermissionMatrix extends StatelessWidget {
  const PermissionMatrix({
    super.key,
    required this.roles,
    required this.catalog,
    required this.value,
    required this.onChanged,
    this.disabled = false,
    this.readOnly = false,
  });

  final List<OrganizationRole> roles;
  final List<PermissionDef> catalog;
  final AccessState value;
  final ValueChanged<AccessState> onChanged;

  /// Geçici kilit (ör. kayıt sürerken) VEYA kalıcı salt-okunur.
  final bool disabled;

  /// Bakan kişi hiç değiştiremez (roles.manage yok): "aşağıdan ekleyip
  /// çıkarabilirsin" gibi yönlendirmeler yerine tarafsız bir açıklama
  /// gösterilir. [disabled]'dan ayrı -- kayıt sürerken metin oynamasın.
  final bool readOnly;

  OrganizationRole? get _role {
    for (final r in roles) {
      if (r.code == value.roleCode) return r;
    }
    return null;
  }

  void _changeRole(String? roleCode) {
    if (roleCode == null) return;
    final next = roles.firstWhere((r) => r.code == roleCode);
    onChanged(AccessState(roleCode: roleCode, selected: {...next.permissions}));
  }

  @override
  Widget build(BuildContext context) {
    final catalogCodes = {for (final p in catalog) p.code};
    final role = _role;
    final roleDefaults = {...?role?.permissions};
    final isOwner = value.roleCode == kOwnerRoleCode;
    final locked = disabled || readOnly || isOwner || role == null;
    final diff = diffCount(value.selected, roleDefaults, catalogCodes);
    bool adminOnly(String code) => isAdminRoleOnlyFor(value.roleCode, code);
    final hasAdminOnly = catalog.any((p) => adminOnly(p.code));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          // initialValue yalnızca ilk çizimde okunur; dışarıdan gelen rol
          // değişikliği (ör. "Değişiklikleri geri al") alanı yenilesin diye
          // anahtar role bağlı.
          key: ValueKey('rol-${value.roleCode}-${roles.length}'),
          initialValue: role?.code,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Rol'),
          hint: const Text('Rol seçin'),
          // Seçili rol adı uzunsa ("Kullanıcı (Eski Sistem) (mevcut rol)")
          // kesilmesin: alana sığacak kadar küçülür.
          selectedItemBuilder: (context) => [
            for (final r in roles)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FittedBox(fit: BoxFit.scaleDown, child: Text(r.name, maxLines: 1)),
              ),
          ],
          items: [
            for (final r in roles)
              DropdownMenuItem(
                value: r.code,
                child: Text(r.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: disabled || readOnly ? null : _changeRole,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          readOnly
              ? 'Rol, yetkilerin başlangıç noktasıdır; kişiye özel farklar aşağıda işaretlidir.'
              : isOwner
              ? 'Rol, yetkilerin başlangıç noktasıdır. Rol değişirse kişiye özel ayarlar sıfırlanır.'
              : 'Rol, yetkilerin başlangıç noktasıdır. Aşağıdan bu kişiye özel ekleme veya çıkarma yapabilirsin; '
                    'aynı roldeki diğer kişiler etkilenmez. Rol değişirse kişiye özel ayarlar sıfırlanır.',
          style: AppTypography.helper,
        ),
        const SizedBox(height: AppSpacing.md),
        if (role == null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: const Text('Yetkileri düzenlemek için önce bir rol seçin.', style: AppTypography.metadata),
          )
        else ...[
          _Summary(
            count: value.selected.length,
            isOwner: isOwner,
            diff: diff,
            onReset: !locked && diff > 0
                ? () => onChanged(AccessState(roleCode: value.roleCode, selected: {...roleDefaults}))
                : null,
          ),
          const SizedBox(height: AppSpacing.xs),
          PermissionChecklist(
            // Rol değişince katlanma durumu da sıfırlansın.
            key: ValueKey('liste-${value.roleCode}'),
            catalog: catalog,
            selected: value.selected,
            enabled: !locked,
            baseline: roleDefaults,
            isLocked: adminOnly,
            onToggle: (code) => onChanged(
              AccessState(roleCode: value.roleCode, selected: togglePermission(value.selected, code, catalogCodes)),
            ),
            onSetCategory: (codes, on) => onChanged(
              AccessState(roleCode: value.roleCode, selected: setPermissions(value.selected, codes, on, catalogCodes)),
            ),
          ),
          // Kutucukları değiştirmeyi anlatan açıklama yalnızca gerçekten
          // değiştirebilen kişiye (salt-okunurda ve Sahip'te kutucuklar kilitli).
          if (!readOnly && !isOwner) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Bir yazma iznini açtığında aynı bölümün görüntüleme izni de açılır; görüntülemeyi kapatınca ona bağlı '
              'yazma izinleri de kapanır. Böylece kimse göremediği bir şeyi düzenlemeye çalışmaz.'
              '${hasAdminOnly ? ' Kullanıcı, rol ve firma ayarı yönetimi yalnızca Sahip veya Yönetici rolündeki kişilere verilebilir.' : ''}',
              style: AppTypography.helper,
            ),
          ],
        ],
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.count, required this.isOwner, required this.diff, this.onReset});

  final int count;
  final bool isOwner;
  final int diff;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final TextSpan suffix;
    if (isOwner) {
      suffix = const TextSpan(
        text: ' · Sahip her zaman tüm yetkilere sahiptir, kısıtlanamaz.',
        style: TextStyle(color: AppColors.textMuted),
      );
    } else if (diff > 0) {
      suffix = TextSpan(
        text: ' · rolden $diff kişiye özel fark',
        style: const TextStyle(color: AppColors.gold, fontWeight: FontWeight.w600),
      );
    } else {
      suffix = const TextSpan(
        text: ' · rolün varsayılanı',
        style: TextStyle(color: AppColors.textMuted),
      );
    }
    return Container(
      padding: EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, onReset == null ? AppSpacing.sm : 0),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$count',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const TextSpan(text: ' izin'),
                suffix,
              ],
            ),
            style: AppTypography.body.copyWith(fontSize: 13),
          ),
          if (onReset != null)
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(0, 36), padding: EdgeInsets.zero),
              onPressed: onReset,
              icon: const Icon(Icons.undo, size: 16),
              label: const Text(
                'Rolün varsayılanına dön',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }
}
