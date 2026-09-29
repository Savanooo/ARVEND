import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_badge.dart';
import '../data/ops_team_providers.dart';
import '../domain/ops_permissions.dart';
import '../domain/project_access.dart';
import 'access_sheets.dart';
import 'widgets/ops_common.dart';

/// "Proje Erişimi" -- bu projeye hangi UYGULAMA KULLANICILARININ hangi proje
/// rolüyle eriştiği (web `ProjectAccessSection`). Okuma
/// `projects.access.read`, ekle/rol değiştir/kaldır `projects.access.manage`.
/// Proje ekibi (personel roster'ı) İLE KARIŞTIRILMAMALI. Proje durumu
/// (tamamlandı/iptal) erişimi kilitlemez -- web ve backend de kilitlemiyor.
class ProjectAccessTab extends ConsumerStatefulWidget {
  const ProjectAccessTab({super.key, required this.projectId, this.padding = const EdgeInsets.all(AppSpacing.lg)});

  final String projectId;
  final EdgeInsetsGeometry padding;

  @override
  ConsumerState<ProjectAccessTab> createState() => _ProjectAccessTabState();
}

class _ProjectAccessTabState extends ConsumerState<ProjectAccessTab> {
  String get _projectId => widget.projectId;

  Future<void> _refresh() async {
    ref.invalidate(opsAccessUsersProvider(_projectId));
    try {
      await ref.read(opsAccessUsersProvider(_projectId).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  // Kapsayıcı sayfa açılmadan ÖNCE alınır: sekme bu arada ağaçtan kalksa da
  // liste tazelenir (WidgetRef dispose sonrası StateError atardı).
  Future<void> _grant(List<ProjectAccessUser> assigned) async {
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    final granted = await showAccessGrantSheet(context, projectId: _projectId, assigned: assigned);
    if (granted == null) return;
    invalidate(opsAccessUsersProvider(_projectId));
    if (mounted) showOpsSnack(context, '${granted.fullName} kullanıcısına erişim verildi.');
  }

  Future<void> _edit(ProjectAccessUser user) async {
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    final result = await showAccessUserSheet(context, projectId: _projectId, user: user);
    if (result == null) return;
    invalidate(opsAccessUsersProvider(_projectId));
    if (!mounted) return;
    showOpsSnack(
      context,
      result == AccessEditResult.revoked
          ? '${user.fullName} kullanıcısının erişimi kaldırıldı.'
          : '${user.fullName} kullanıcısının proje rolü güncellendi.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    // Oturum henüz yüklenmediyse karar verilmez (fail-open bir istek atmasın).
    if (user == null && auth.isLoading) return const LoadingState();
    if (!user.can(kProjectAccessReadPermission)) {
      return const NoAccessView(message: kAccessNoAccessText);
    }
    final canManage = user.can(kProjectAccessManagePermission);
    // "Erişim Ver"in kullanıcı seçicisi `GET /users` ister: requireAdmin +
    // organization.users.read (canAccess ikisini birlikte denetler). Rolü
    // Yönetici olmayan ama projects.access.manage'i kişiye özel almış biri
    // hiç tamamlanamayan bir forma yönlendirilmesin; rol değiştirme/kaldırma
    // yalnızca projects.access.manage ister.
    final canGrant = canManage && user.canAccess(kOrgUsersReadPermission);
    final usersAsync = ref.watch(opsAccessUsersProvider(_projectId));

    if (usersAsync.hasError && isOpsForbidden(usersAsync.error)) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: const NoAccessView(message: kAccessNoAccessText, scrollable: true),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: widget.padding,
        children: [
          // "Proje Erişimi" zaten AppBar'da (tam ekran) ya da seçili çipte yazılı.
          AppSectionHeader(
            title: 'Erişimi Olan Kullanıcılar',
            trailing: canGrant && usersAsync.hasValue
                ? TextButton.icon(
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Erişim Ver'),
                    onPressed: () => _grant(usersAsync.requireValue),
                  )
                : null,
          ),
          const SizedBox(height: AppSpacing.xs),
          const Text(kAccessExplainText, style: AppTypography.helper),
          if (!canManage) ...[
            const SizedBox(height: AppSpacing.md),
            const ReadOnlyNotice(kAccessReadOnlyText),
          ] else if (!canGrant) ...[
            const SizedBox(height: AppSpacing.md),
            const ReadOnlyNotice(kAccessNoUserListText),
          ],
          const SizedBox(height: AppSpacing.md),
          AsyncStateView<List<ProjectAccessUser>>(
            value: usersAsync,
            onRetry: _refresh,
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) =>
                const OpsEmptyCard('Bu projeye açıkça atanmış kullanıcı yok.', icon: Icons.admin_panel_settings_outlined),
            data: (context, users) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final u in users) AccessUserCard(user: u, onTap: canManage ? () => _edit(u) : null),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Erişim satırı: ad, kullanıcı adı + organizasyon rolü, proje rolü rozeti,
/// pasifse "Pasif". Yönetebilen kişi dokununca rol/kaldır sayfası açılır.
class AccessUserCard extends StatelessWidget {
  const AccessUserCard({super.key, required this.user, this.onTap});

  final ProjectAccessUser user;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final meta = [
      user.username,
      if (user.organizationRoleName.isNotEmpty) user.organizationRoleName,
    ].join(' · ');
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        children: [
          OpsInitialsAvatar(name: user.fullName, muted: !user.userIsActive),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(user.fullName, style: AppTypography.cardTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                // 2 satır: geniş proje rolü rozeti yanında organizasyon rolü
                // ("selin.aydin · Proj...") kesiliyordu.
                Text(meta, style: AppTypography.metadata, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              projectRoleBadge(user.projectRole),
              if (!user.userIsActive) ...[
                const SizedBox(height: 4),
                const StatusBadge(label: 'Pasif', tone: StatusTone.danger),
              ],
            ],
          ),
          if (onTap != null) const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
  }
}
