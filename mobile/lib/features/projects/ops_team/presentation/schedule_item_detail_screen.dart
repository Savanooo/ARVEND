import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_data_row.dart';
import '../../../../core/widgets/app_lifecycle_actions.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../../../core/widgets/viz/progress_bar.dart';
import '../../data/projects_providers.dart';
import '../../presentation/destructive_action_button.dart';
import '../data/ops_team_providers.dart';
import '../domain/ops_permissions.dart';
import '../domain/schedule_item.dart';
import '../ops_team_paths.dart';
import 'widgets/ops_common.dart';

/// Tek planlama aşaması. Backend'de tekil GET ucu YOK -- aşama, listeden
/// (`GET /schedule`) bulunur. Durum aksiyonları web'deki durum seçicisinin
/// karşılığıdır (backend'de geçiş grafiği yok; her geçiş `PUT` ile TÜM
/// alanlar korunarak yapılır). Silme ucu olmadığı için "İptal Et" aşamayı
/// "İptal" durumuna alır, kayıt listede kalır.
class ScheduleItemDetailScreen extends ConsumerStatefulWidget {
  const ScheduleItemDetailScreen({super.key, required this.projectId, required this.itemId});

  final String projectId;
  final String itemId;

  @override
  ConsumerState<ScheduleItemDetailScreen> createState() => _ScheduleItemDetailScreenState();
}

class _ScheduleItemDetailScreenState extends ConsumerState<ScheduleItemDetailScreen> {
  bool _busy = false;

  Future<void> _refresh() async {
    ref.invalidate(opsScheduleProvider(widget.projectId));
    try {
      await ref.read(opsScheduleProvider(widget.projectId).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  Future<void> _setStatus(ScheduleItem item, String status) async {
    setState(() => _busy = true);
    // Kapsayıcı ilk await'ten ÖNCE: istek sürerken geri basılıp ekran
    // kapansa da Planlama listesi tazelenir.
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      await ref.read(opsTeamRepositoryProvider).updateScheduleItem(
            widget.projectId,
            item.id,
            item.toInput(status: status),
          );
      invalidate(opsScheduleProvider(widget.projectId));
      if (mounted) showOpsSnack(context, 'Aşama "${ScheduleStatus.label(status)}" olarak güncellendi.');
    } catch (e) {
      // 409 (ör. başka biri durumu değiştirdi / proje kilitlendi): mesajı
      // göster ve güncel hali yeniden çek.
      if (isOpsConflict(e)) invalidate(opsScheduleProvider(widget.projectId));
      if (mounted) showOpsSnack(context, opsErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    const fallbackTitle = Text('Planlama Aşaması');
    if (user == null && auth.isLoading) return const AppPageScaffold(title: fallbackTitle, body: LoadingState());
    if (!user.can(kProjectOpsReadPermission)) {
      return const AppPageScaffold(title: fallbackTitle, body: NoAccessView(message: kScheduleNoAccessText));
    }
    final canManage = user.can(kProjectOpsManagePermission);
    final projectStatus = ref.watch(projectDetailProvider(widget.projectId)).valueOrNull?.status;
    final locked = projectStatus == null ? null : isProjectLocked(projectStatus);
    final canWrite = canManage && locked == false;
    final today = ref.watch(opsTodayProvider);
    final scheduleAsync = ref.watch(opsScheduleProvider(widget.projectId));
    ScheduleItem? item;
    for (final s in scheduleAsync.valueOrNull ?? const <ScheduleItem>[]) {
      if (s.id == widget.itemId) item = s;
    }
    final current = item;

    // AppBar varlık türünü söyler; aşamanın adı gövde başlığında tam yazılır
    // (iki kez tekrarlanmaz). Düzenle tek yerde: aksiyon çubuğunda.
    return AppPageScaffold(
      title: fallbackTitle,
      body: scheduleAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => isOpsForbidden(e)
            ? const NoAccessView(message: kScheduleNoAccessText)
            : ErrorState(error: e, onRetry: _refresh),
        data: (_) => current == null
            ? const EmptyStateView(message: 'Aşama bulunamadı.', icon: Icons.search_off)
            : RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
                  children: [
                    _Header(item: current, today: today),
                    if (locked == true) ...[
                      const SizedBox(height: AppSpacing.md),
                      const OpsLockedNotice(),
                    ] else if (!canManage) ...[
                      const SizedBox(height: AppSpacing.md),
                      const ReadOnlyNotice(kScheduleReadOnlyText),
                    ],
                    if (current.isOverdue(today)) ...[
                      const SizedBox(height: AppSpacing.md),
                      _OverdueBanner(item: current, days: current.overdueDays(today)),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                    const Text('Bilgiler', style: AppTypography.sectionTitle),
                    const SizedBox(height: AppSpacing.sm),
                    AppCard(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Durum başlıktaki rozette; burada tekrarlanmaz.
                          AppDataRow(
                            label: 'Sorumlu',
                            value: current.assignedName.isNotEmpty ? current.assignedName : 'Atanmadı',
                          ),
                          AppDataRow(label: 'Başlangıç', value: dayText(current.startDate)),
                          AppDataRow(label: 'Bitiş', value: dayText(current.endDate)),
                          AppDataRow(
                            label: 'Süre',
                            value: current.durationDays == null ? '—' : '${current.durationDays} gün',
                          ),
                          AppDataRow(
                            label: 'Bağlı görevler',
                            value: current.taskCount == 0
                                ? 'Görev yok'
                                : '${current.completedTaskCount}/${current.taskCount} tamamlandı',
                          ),
                          if (current.taskProgressPct != null) ...[
                            const SizedBox(height: AppSpacing.xs),
                            AppProgressBar(
                              pct: current.taskProgressPct,
                              color: AppColors.success,
                              semanticsLabel: 'Görev ilerlemesi',
                            ),
                            const SizedBox(height: AppSpacing.sm),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    const Text('Açıklama', style: AppTypography.sectionTitle),
                    const SizedBox(height: AppSpacing.sm),
                    AppCard(
                      child: Text(
                        current.description.isEmpty ? 'Açıklama yok.' : current.description,
                        style: current.description.isEmpty ? AppTypography.metadata : AppTypography.body,
                      ),
                    ),
                    if (canWrite) ...[
                      const SizedBox(height: AppSpacing.xl),
                      AppLifecycleActions(actions: _actions(current)),
                      if (current.isOpen) ...[
                        const SizedBox(height: AppSpacing.sm),
                        DestructiveActionButton(
                          label: 'İptal Et',
                          onPressed: _busy ? null : () => _cancel(current),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  List<AppLifecycleAction> _actions(ScheduleItem item) {
    final disabled = _busy;
    final quoted = '"${item.name}"';
    AppLifecycleAction confirmTo(
      String status, {
      required String label,
      required IconData icon,
      required String title,
      required String message,
      bool primary = false,
      bool danger = false,
    }) =>
        AppLifecycleAction(
          label: label,
          icon: icon,
          primary: primary,
          loading: _busy && primary,
          onPressed: disabled
              ? null
              : () async {
                  final ok = await confirmOpsAction(
                    context,
                    title: title,
                    message: message,
                    confirmLabel: label,
                    danger: danger,
                  );
                  if (ok) await _setStatus(item, status);
                },
        );

    final actions = <AppLifecycleAction>[];
    switch (item.status) {
      case ScheduleStatus.planned:
        actions.add(AppLifecycleAction(
          label: 'Başlat',
          icon: Icons.play_arrow,
          primary: true,
          loading: _busy,
          onPressed: disabled ? null : () => _setStatus(item, ScheduleStatus.active),
        ));
      case ScheduleStatus.active:
        actions.add(confirmTo(
          ScheduleStatus.completed,
          label: 'Tamamla',
          icon: Icons.check_circle_outline,
          primary: true,
          title: 'Aşamayı Tamamla',
          message: '$quoted aşaması tamamlandı olarak işaretlensin mi?',
        ));
      case ScheduleStatus.completed:
        actions.add(confirmTo(
          ScheduleStatus.active,
          label: 'Yeniden Aç',
          icon: Icons.replay,
          title: 'Aşamayı Yeniden Aç',
          message: '$quoted aşaması yeniden "Devam Ediyor" durumuna alınsın mı?',
        ));
      case ScheduleStatus.cancelled:
        actions.add(confirmTo(
          ScheduleStatus.planned,
          label: 'Yeniden Planla',
          icon: Icons.replay,
          title: 'Aşamayı Yeniden Planla',
          message: '$quoted aşaması yeniden "Planlandı" durumuna alınsın mı?',
        ));
    }
    actions.add(AppLifecycleAction(
      label: 'Düzenle',
      icon: Icons.edit_outlined,
      onPressed: disabled ? null : () => context.push(scheduleItemEditPath(widget.projectId, item.id)),
    ));
    return actions;
  }

  /// "İptal Et" aksiyon çubuğundan ayrı, kırmızı (bkz. DestructiveActionButton).
  Future<void> _cancel(ScheduleItem item) async {
    final ok = await confirmOpsAction(
      context,
      title: 'Aşamayı İptal Et',
      message: '"${item.name}" aşaması iptal edilsin mi? Aşama silinmez; "İptal" durumunda listede kalır.',
      confirmLabel: 'İptal Et',
      danger: true,
    );
    if (ok) await _setStatus(item, ScheduleStatus.cancelled);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.item, required this.today});

  final ScheduleItem item;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            scheduleStatusBadge(item.status),
            if (item.isOverdue(today)) const StatusBadge(label: 'Gecikti', tone: StatusTone.danger),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        // Tarihler aşağıdaki "Bilgiler" kartında; başlıkta tekrar edilmez.
        Text(item.name, style: AppTypography.pageTitle),
      ],
    );
  }
}

class _OverdueBanner extends StatelessWidget {
  const _OverdueBanner({required this.item, required this.days});

  final ScheduleItem item;
  final int days;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.danger),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Bitiş tarihi $days gün önce geçti; aşama hâlâ "${ScheduleStatus.label(item.status)}".',
              style: AppTypography.helper.copyWith(color: AppColors.danger, height: 1.35, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
