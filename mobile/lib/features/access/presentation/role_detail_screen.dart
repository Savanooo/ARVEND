import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../data/access_providers.dart';
import '../domain/access_models.dart';
import '../domain/permission_rules.dart';
import 'roles_screen.dart';
import 'widgets/access_state_views.dart';
import 'widgets/permission_checklist.dart';

/// Tek bir rolün izin kümesi -- web `RolesManager` sağ paneli. Kaydetme
/// PUT /organization/roles/{id}/permissions (roles.manage). Sahip rolü
/// kilitlidir: firmanın kendini kilitlemesini önlemek için mobilden
/// değiştirilemez.
class RoleDetailScreen extends ConsumerWidget {
  const RoleDetailScreen({super.key, required this.roleId});

  final String roleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authControllerProvider).valueOrNull;
    if (!me.canAccess('organization.roles.read')) {
      return const AppPageScaffold(
        title: Text('Rol'),
        body: NoAccessView(message: kRolesNoAccessMessage),
      );
    }
    final canManage = me.canAccess('organization.roles.manage');
    final dataAsync = ref.watch(roleCatalogProvider);
    OrganizationRole? findRole(RoleCatalog d) {
      for (final r in d.roles) {
        if (r.id == roleId) return r;
      }
      return null;
    }

    Future<void> refresh() => refreshAndWait(ref, [
      organizationRolesProvider,
      permissionCatalogProvider,
    ], () => ref.read(roleCatalogProvider.future));

    final role = dataAsync.valueOrNull == null ? null : findRole(dataAsync.valueOrNull!);
    return AppPageScaffold(
      title: Text(role?.name ?? 'Rol'),
      body: GuardedAsyncView<RoleCatalog>(
        value: dataAsync,
        onRetry: refresh,
        keepDataWhileReloading: true,
        data: (context, d) {
          final role = findRole(d);
          if (role == null) {
            return const EmptyStateView(message: 'Rol bulunamadı.', icon: Icons.shield_outlined);
          }
          return _RoleEditor(
            // Rolün kimliğine bağlı: yenileme (aşağı çekme, başka ekranın
            // tazelemesi) kaydedilmemiş seçimleri silmez -- didUpdateWidget.
            key: ValueKey('rol-${role.id}'),
            role: role,
            catalog: d.catalog,
            canManage: canManage,
            onRefresh: refresh,
          );
        },
      ),
    );
  }
}

class _RoleEditor extends ConsumerStatefulWidget {
  const _RoleEditor({
    super.key,
    required this.role,
    required this.catalog,
    required this.canManage,
    required this.onRefresh,
  });

  final OrganizationRole role;
  final List<PermissionDef> catalog;
  final bool canManage;
  final Future<void> Function() onRefresh;

  @override
  ConsumerState<_RoleEditor> createState() => _RoleEditorState();
}

class _RoleEditorState extends ConsumerState<_RoleEditor> {
  /// Sunucuda kayıtlı izin kümesi (karşılaştırma tabanı).
  late Set<String> _saved = {...widget.role.permissions};
  late Set<String> _selected = {..._saved};
  bool _saving = false;
  String? _error;

  bool get _canEdit => widget.canManage && !widget.role.isOwner;
  bool get _dirty => !sameSet(_selected, _saved);

  /// Sunucudan yeni rol verisi geldi: seçim kaydedilmemişse yeni duruma
  /// geçilir; kaydedilmemiş seçim varsa KORUNUR, yalnızca taban güncellenir.
  @override
  void didUpdateWidget(covariant _RoleEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.role, widget.role)) return;
    final server = {...widget.role.permissions};
    if (!_dirty) _selected = {...server};
    _saved = server;
  }

  void _toggle(String code) => setState(() {
    final next = {..._selected};
    if (!next.remove(code)) next.add(code);
    _selected = next;
  });

  void _setCategory(List<String> codes, bool on) => setState(() {
    final next = {..._selected};
    on ? next.addAll(codes) : next.removeAll(codes);
    _selected = next;
  });

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    // Kayıt sürerken ekran kapanabilir: tazeleme yine yapılsın diye
    // kapsayıcı ilk await'ten ÖNCE alınır.
    final container = ProviderScope.containerOf(context, listen: false);
    final role = widget.role;
    final target = {..._selected};
    try {
      await container.read(accessRepositoryProvider).setRolePermissions(role.id, target);
      container.invalidate(organizationRolesProvider);
      container.invalidate(userAccessBundleProvider);
      if (mounted) {
        setState(() => _saved = target);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kaydedildi.')));
      }
      final me = container.read(authControllerProvider).valueOrNull;
      if (me != null && me.organizationRoleCode == role.code) {
        await container.read(authControllerProvider.notifier).refresh();
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final role = widget.role;
    return UnsavedChangesScope(
      dirty: _dirty,
      busy: _saving,
      child: _buildBody(role),
    );
  }

  Widget _buildBody(OrganizationRole role) {
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: widget.onRefresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                Text(role.name, style: AppTypography.pageTitle),
                if (role.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(role.description, style: AppTypography.metadata),
                ],
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.xs,
                  children: [
                    StatusBadge(label: '${_selected.length} izin', tone: StatusTone.muted),
                    if (role.isSystem) const StatusBadge(label: 'Sistem rolü', tone: StatusTone.info),
                    if (_dirty) const StatusBadge(label: 'Kaydedilmedi', tone: StatusTone.warning),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                if (role.isOwner)
                  const InfoNote(
                    'Sahip rolü kilitlidir: firmanın kendini kilitlemesini önlemek için yetkileri değiştirilemez.',
                    icon: Icons.lock_outline,
                  )
                else if (!widget.canManage)
                  const ReadOnlyNotice(
                    'Rolün yetkilerini yalnızca görüntüleyebilirsin; değiştirmek için rolünde "Rolleri ve '
                    'izinlerini düzenleme" izni olmalı.',
                  )
                else
                  const InfoNote(
                    'Buradaki değişiklik bu roldeki herkesi etkiler (kişiye özel ayarlar korunur).',
                    tone: NoteTone.warning,
                  ),
                const SizedBox(height: AppSpacing.md),
                AppCard(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.xs),
                  child: PermissionChecklist(
                    catalog: widget.catalog,
                    selected: _selected,
                    enabled: _canEdit && !_saving,
                    onToggle: _toggle,
                    onSetCategory: _setCategory,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_canEdit)
          Container(
            decoration: const BoxDecoration(
              color: AppColors.surface,
              border: Border(top: BorderSide(color: AppColors.border)),
            ),
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    Text(_error!, style: AppTypography.error),
                    const SizedBox(height: AppSpacing.xs),
                  ],
                  Row(
                    children: [
                      if (_dirty && !_saving) ...[
                        Expanded(
                          child: SecondaryButton(
                            label: 'Geri Al',
                            onPressed: () => setState(() {
                              _selected = {..._saved};
                              _error = null;
                            }),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                      ],
                      Expanded(
                        flex: 2,
                        child: PrimaryButton(label: 'Kaydet', loading: _saving, onPressed: _dirty ? _save : null),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
