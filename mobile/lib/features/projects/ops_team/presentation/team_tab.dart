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
import '../../data/projects_providers.dart';
import '../data/ops_team_providers.dart';
import '../domain/ops_permissions.dart';
import '../domain/team_member.dart';
import 'team_member_add_sheet.dart';
import 'widgets/ops_common.dart';

/// "Personel / Ekip" -- proje ekibi (İK/puantaj roster'ı). Web
/// `MembersSection` ile aynı: Aktif Ekip + Geçmiş Ekip, "Ekibe Ekle",
/// "Ekipten Çıkar". Ekipten çıkarma kaydı SİLMEZ (bitiş tarihi yazar); mobil
/// bunu bir onayla yapar. Uygulama kullanıcılarının proje erişimi AYRI bir
/// ekrandır (bkz. access_tab.dart).
///
/// [locked]: proje tamamlandı/iptal. `null` = proje henüz bilinmiyor
/// (yazma düğmeleri gizli).
class ProjectTeamTab extends ConsumerStatefulWidget {
  const ProjectTeamTab({
    super.key,
    required this.projectId,
    required this.locked,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
  });

  final String projectId;
  final bool? locked;
  final EdgeInsetsGeometry padding;

  @override
  ConsumerState<ProjectTeamTab> createState() => _ProjectTeamTabState();
}

class _ProjectTeamTabState extends ConsumerState<ProjectTeamTab> {
  String? _removingId;

  String get _projectId => widget.projectId;

  /// [invalidate]: bir await'ten sonra çağrılırken kapsayıcının ilk
  /// await'ten ÖNCE alınmış hali -- sekme bu arada ağaçtan kalksa da (grup
  /// değişti, geri basıldı) tazeleme yapılır.
  void _invalidateAll(void Function(ProviderOrFamily provider) invalidate) {
    invalidate(opsTeamMembersProvider(_projectId));
    // Operasyon özetindeki "Ekip" sayısı (proje detayı) bayatlamasın.
    invalidate(projectOperationsSummaryProvider(_projectId));
  }

  Future<void> _refresh() async {
    ref.invalidate(opsTeamMembersProvider(_projectId));
    try {
      await ref.read(opsTeamMembersProvider(_projectId).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  Future<void> _add(List<ProjectTeamMember> members) async {
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    final added = await showTeamMemberAddSheet(
      context,
      projectId: _projectId,
      activeEmployeeIds: {for (final m in members) if (m.isActive) m.employeeId},
    );
    if (added == null) return;
    _invalidateAll(invalidate);
    if (mounted) showOpsSnack(context, '${added.employeeName} ekibe eklendi.');
  }

  Future<void> _remove(ProjectTeamMember m) async {
    final ok = await confirmOpsAction(
      context,
      title: 'Ekipten Çıkar',
      message: '${m.employeeName} ekipten çıkarılsın mı? Kayıt silinmez; bugünün tarihiyle "Geçmiş Ekip"e taşınır.',
      confirmLabel: 'Ekipten Çıkar',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _removingId = m.id);
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      await ref.read(opsTeamRepositoryProvider).endMembership(_projectId, m.id);
      _invalidateAll(invalidate);
      if (mounted) showOpsSnack(context, '${m.employeeName} ekipten çıkarıldı.');
    } catch (e) {
      if (isOpsConflict(e)) invalidate(opsTeamMembersProvider(_projectId));
      if (mounted) showOpsSnack(context, opsErrorText(e));
    } finally {
      if (mounted) setState(() => _removingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    // Oturum henüz yüklenmediyse karar verilmez (fail-open bir istek atmasın).
    if (user == null && auth.isLoading) return const LoadingState();
    if (!user.can(kProjectOpsReadPermission)) {
      return const NoAccessView(message: kTeamNoAccessText);
    }
    final canManage = user.can(kProjectOpsManagePermission);
    final canWrite = canManage && widget.locked == false;
    // "Ekibe Ekle"nin seçicisi projenin `assignees` ucundan gelir (ücretsiz,
    // projects.read yeter) -- eskiden `GET /employees` (employees.read)
    // istendiği için Proje Yöneticisi/Saha ekibe hiç ekleyemiyordu.
    final canAdd = canWrite;
    final membersAsync = ref.watch(opsTeamMembersProvider(_projectId));

    if (membersAsync.hasError && isOpsForbidden(membersAsync.error)) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: const NoAccessView(message: kTeamNoAccessText, scrollable: true),
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: widget.padding,
        children: [
          AppSectionHeader(
            title: 'Personel / Ekip',
            trailing: canAdd && membersAsync.hasValue
                ? TextButton.icon(
                    icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                    label: const Text('Ekibe Ekle'),
                    onPressed: () => _add(membersAsync.requireValue),
                  )
                : null,
          ),
          if (widget.locked == true) ...[
            const SizedBox(height: AppSpacing.sm),
            const OpsLockedNotice(),
          ] else if (!canManage) ...[
            const SizedBox(height: AppSpacing.sm),
            const ReadOnlyNotice(kTeamReadOnlyText),
          ],
          const SizedBox(height: AppSpacing.md),
          AsyncStateView<List<ProjectTeamMember>>(
            value: membersAsync,
            onRetry: _refresh,
            data: (context, members) {
              final active = [for (final m in members) if (m.isActive) m];
              final past = [for (final m in members) if (!m.isActive) m];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('AKTİF EKİP (${active.length})', style: AppTypography.overline),
                  const SizedBox(height: AppSpacing.sm),
                  if (active.isEmpty)
                    const OpsEmptyCard('Henüz ekip üyesi atanmamış.', icon: Icons.groups_outlined)
                  else
                    for (final m in active)
                      _ActiveMemberCard(
                        member: m,
                        removing: _removingId == m.id,
                        onRemove: canWrite && _removingId == null ? () => _remove(m) : null,
                      ),
                  if (past.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.lg),
                    _PastMembers(members: past),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ActiveMemberCard extends StatelessWidget {
  const _ActiveMemberCard({required this.member, required this.removing, this.onRemove});

  final ProjectTeamMember member;
  final bool removing;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final meta = [
      if (member.roleTitle.isNotEmpty) member.roleTitle,
      if (member.startDate != null) 'Başlangıç ${dayText(member.startDate)}',
    ].join(' · ');
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.xs, AppSpacing.sm),
      child: Row(
        children: [
          OpsInitialsAvatar(name: member.employeeName),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(member.employeeName, style: AppTypography.cardTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                // 2 satır: çıkarma simgesinin yanında "Şantiye Şefi · Başlangıç
                // 01.08.2026" 360 dp'de yılı kesiyordu.
                if (meta.isNotEmpty)
                  Text(meta, style: AppTypography.metadata, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (member.notes.isNotEmpty)
                  Text(member.notes, style: AppTypography.helper, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (removing)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (onRemove != null)
            IconButton(
              tooltip: 'Ekipten Çıkar',
              icon: const Icon(Icons.person_remove_outlined, color: AppColors.danger, size: 20),
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}

/// Web'deki katlanır `<details>` "Geçmiş Ekip (N)" karşılığı.
class _PastMembers extends StatefulWidget {
  const _PastMembers({required this.members});

  final List<ProjectTeamMember> members;

  @override
  State<_PastMembers> createState() => _PastMembersState();
}

class _PastMembersState extends State<_PastMembers> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
            child: Row(
              children: [
                Expanded(child: Text('GEÇMİŞ EKİP (${widget.members.length})', style: AppTypography.overline)),
                Icon(_open ? Icons.expand_less : Icons.expand_more, color: AppColors.textMuted, size: 20),
              ],
            ),
          ),
        ),
        if (_open) ...[
          const SizedBox(height: AppSpacing.xs),
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
            child: Column(
              children: [
                for (var i = 0; i < widget.members.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                    child: Row(
                      children: [
                        OpsInitialsAvatar(name: widget.members[i].employeeName, muted: true),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(child: _pastText(widget.members[i])),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _pastText(ProjectTeamMember m) {
    final meta = [
      if (m.roleTitle.isNotEmpty) m.roleTitle,
      if (m.endDate != null) 'ayrıldı ${dayText(m.endDate)}',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(m.employeeName, style: AppTypography.body.copyWith(color: AppColors.textMuted)),
        if (meta.isNotEmpty) Text(meta, style: AppTypography.helper),
      ],
    );
  }
}
