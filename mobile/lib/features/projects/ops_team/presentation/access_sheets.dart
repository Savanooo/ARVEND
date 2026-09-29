import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_form_section.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../../../core/widgets/unsaved_changes_scope.dart';
import '../data/ops_team_providers.dart';
import '../domain/project_access.dart';
import 'widgets/ops_common.dart';

/// Erişim düzenleme sonucunun türü (liste mesajı için).
enum AccessEditResult { roleChanged, revoked }

// ---------- Erişim Ver ----------

/// "Erişim Ver" alt sayfası; erişim verilen kullanıcıyı döner. Yalnızca
/// `projects.access.manage` sahibine gösterilen düğmeden çağrılır.
Future<OrgUserOption?> showAccessGrantSheet(
  BuildContext context, {
  required String projectId,
  required List<ProjectAccessUser> assigned,
}) {
  return showModalBottomSheet<OrgUserOption>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: false,
    builder: (_) => AccessGrantSheet(projectId: projectId, assigned: assigned),
  );
}

/// Web formu: Kullanıcı seçin + Proje rolü (varsayılan Üye) + "Erişim Ver".
/// Seçicide yalnızca aktif ve henüz erişimi olmayan kullanıcılar var.
class AccessGrantSheet extends ConsumerStatefulWidget {
  const AccessGrantSheet({super.key, required this.projectId, required this.assigned});

  final String projectId;
  final List<ProjectAccessUser> assigned;

  @override
  ConsumerState<AccessGrantSheet> createState() => _AccessGrantSheetState();
}

class _AccessGrantSheetState extends ConsumerState<AccessGrantSheet> {
  final _formKey = GlobalKey<FormState>();
  String? _userId;
  String _role = ProjectRole.member;
  bool _submitting = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final usersAsync = ref.watch(opsOrgUserOptionsProvider);
    final available = usersAsync.hasValue ? grantableUsers(usersAsync.requireValue, widget.assigned) : const <OrgUserOption>[];
    return UnsavedChangesScope(
      busy: _submitting,
      dirty: _userId != null && !_submitting,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Erişim Ver', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
              const SizedBox(height: AppSpacing.xs),
              const Text(kAccessExplainText, style: AppTypography.helper),
              const SizedBox(height: AppSpacing.lg),
              AppFormSection(
                title: 'Erişim Verilecek Kişi',
                children: [
                  usersAsync.when(
                    loading: () => const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                      child: LinearProgressIndicator(),
                    ),
                    error: (e, _) => Text(
                      isOpsForbidden(e) ? 'Kullanıcı listesini görüntüleme yetkin yok.' : opsErrorText(e),
                      style: AppTypography.error,
                    ),
                    data: (_) => available.isEmpty
                        ? const Text('Erişim verilebilecek aktif kullanıcı yok.', style: AppTypography.metadata)
                        : DropdownButtonFormField<String>(
                            key: const ValueKey('access-user'),
                            initialValue: _userId,
                            isExpanded: true,
                            decoration: const InputDecoration(labelText: 'Kullanıcı *', hintText: 'Kullanıcı seç'),
                            items: [
                              for (final u in available)
                                DropdownMenuItem(
                                  value: u.id,
                                  child: Text(u.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                                ),
                            ],
                            onChanged: _submitting ? null : (v) => setState(() => _userId = v),
                            validator: (v) => v == null ? 'Kullanıcı seç' : null,
                          ),
                  ),
                ],
              ),
              AppFormSection(
                title: 'Proje rolü',
                subtitle: kProjectRoleHelpText,
                spacing: AppSpacing.sm,
                children: [
                  for (final r in ProjectRole.values)
                    ProjectRoleOption(
                      role: r,
                      selected: _role == r,
                      onTap: _submitting ? null : () => setState(() => _role = r),
                    ),
                ],
              ),
              if (_error != null) ...[
                Text(_error!, style: AppTypography.error),
                const SizedBox(height: AppSpacing.md),
              ],
              PrimaryButton(
                label: 'Erişim Ver',
                loading: _submitting,
                onPressed: available.isEmpty ? null : () => _submit(available),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                child: const Text('Vazgeç'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit(List<OrgUserOption> available) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final userId = _userId;
    if (userId == null) return;
    final chosen = available.firstWhere((u) => u.id == userId);
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(opsTeamRepositoryProvider).grantAccess(widget.projectId, userId: userId, projectRole: _role);
      if (mounted) {
        setState(() => _submitting = false);
        Navigator.of(context).pop(chosen);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = opsErrorText(e);
          _submitting = false;
        });
      }
    }
  }
}

// ---------- Rol değiştir / Erişimi kaldır ----------

/// Tek kullanıcının erişim sayfası: proje rolünü değiştir veya erişimi
/// kaldır. Yalnızca `projects.access.manage` sahibi açabilir.
Future<AccessEditResult?> showAccessUserSheet(
  BuildContext context, {
  required String projectId,
  required ProjectAccessUser user,
}) {
  return showModalBottomSheet<AccessEditResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: false,
    builder: (_) => AccessUserSheet(projectId: projectId, user: user),
  );
}

class AccessUserSheet extends ConsumerStatefulWidget {
  const AccessUserSheet({super.key, required this.projectId, required this.user});

  final String projectId;
  final ProjectAccessUser user;

  @override
  ConsumerState<AccessUserSheet> createState() => _AccessUserSheetState();
}

class _AccessUserSheetState extends ConsumerState<AccessUserSheet> {
  late String _role = widget.user.projectRole;
  bool _saving = false;
  bool _revoking = false;
  String? _error;

  bool get _busy => _saving || _revoking;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(opsTeamRepositoryProvider).changeAccessRole(
            widget.projectId,
            userId: widget.user.userId,
            projectRole: _role,
          );
      if (mounted) {
        setState(() => _saving = false);
        Navigator.of(context).pop(AccessEditResult.roleChanged);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = opsErrorText(e);
          _saving = false;
        });
      }
    }
  }

  Future<void> _revoke() async {
    final u = widget.user;
    final ok = await confirmOpsAction(
      context,
      title: 'Erişimi Kaldır',
      message: '${u.fullName} adlı kullanıcının bu projeye erişimi kaldırılsın mı?',
      confirmLabel: 'Kaldır',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() {
      _revoking = true;
      _error = null;
    });
    try {
      await ref.read(opsTeamRepositoryProvider).revokeAccess(widget.projectId, userId: u.userId);
      if (mounted) {
        setState(() => _revoking = false);
        Navigator.of(context).pop(AccessEditResult.revoked);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = opsErrorText(e);
          _revoking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    return UnsavedChangesScope(
      busy: _busy,
      dirty: _role != u.projectRole && !_busy,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                OpsInitialsAvatar(name: u.fullName, muted: !u.userIsActive),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(u.fullName, style: AppTypography.pageTitle.copyWith(fontSize: 17)),
                      Text(
                        [u.username, if (u.organizationRoleName.isNotEmpty) u.organizationRoleName].join(' · '),
                        style: AppTypography.metadata,
                      ),
                    ],
                  ),
                ),
                if (!u.userIsActive) const StatusBadge(label: 'Pasif', tone: StatusTone.danger),
              ],
            ),
            const SizedBox(height: AppSpacing.xl),
            AppFormSection(
              title: 'Proje rolü',
              subtitle: kProjectRoleHelpText,
              spacing: AppSpacing.sm,
              children: [
                for (final r in ProjectRole.values)
                  ProjectRoleOption(
                    role: r,
                    selected: _role == r,
                    onTap: _busy ? null : () => setState(() => _role = r),
                  ),
              ],
            ),
            if (_error != null) ...[
              Text(_error!, style: AppTypography.error),
              const SizedBox(height: AppSpacing.md),
            ],
            PrimaryButton(
              label: 'Kaydet',
              loading: _saving,
              onPressed: _role == u.projectRole || _revoking ? null : _save,
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              icon: _revoking
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.person_off_outlined, size: 18),
              label: const Text('Erişimi Kaldır'),
              onPressed: _busy ? null : _revoke,
            ),
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              child: const Text('Vazgeç'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tek bir proje rolü seçeneği (seçili olan gold çerçeveli).
class ProjectRoleOption extends StatelessWidget {
  const ProjectRoleOption({super.key, required this.role, required this.selected, this.onTap});

  final String role;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.gold : AppColors.border;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.control),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? AppColors.gold.withValues(alpha: 0.06) : AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.control),
            border: Border.all(color: color, width: selected ? 1.5 : 1),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 20,
                color: selected ? AppColors.gold : AppColors.textMuted,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: Text(ProjectRole.label(role), style: AppTypography.body)),
            ],
          ),
        ),
      ),
    );
  }
}
