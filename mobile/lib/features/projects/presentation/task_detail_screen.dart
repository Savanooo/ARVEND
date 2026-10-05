import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../../tasks/data/tasks_providers.dart';
import '../../tasks/presentation/task_update_sheet.dart';
import '../data/projects_providers.dart';
import '../domain/project.dart';

/// Faz 7 — Görev detayı. Backend'de AYRI bir "tek görev getir" ucu YOKTUR
/// (yalnızca liste + güncelle + tamamla, bkz. Phase 1 doğrulaması) -- bu
/// ekran, zaten TAM alan kümesini taşıyan proje görev listesinden
/// (`projectTasksProvider`) ilgili görevi bulur; ayrı bir ağ isteği İCAT
/// ETMEZ. "Oluşturan" alanı GÖSTERİLMEZ -- backend bunu DB'de tutsa da API
/// yanıtına HİÇ koymaz (bkz. Phase 1: `ToDomainTask` bunu bilinçli olarak
/// atar) -- var olmayan bir alan İCAT EDİLMEZ. "Proje" bağlam satırı,
/// zaten var olan `projectDetailProvider` (`GET /projects/{id}`) ile
/// doldurulur -- yeni bir uç İCAT EDİLMEZ.
class TaskDetailScreen extends ConsumerWidget {
  const TaskDetailScreen({
    super.key,
    required this.projectId,
    required this.taskId,
  });
  final String projectId;
  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasksAsync = ref.watch(projectTasksProvider(projectId));

    return AppPageScaffold(
      title: const Text('Görev'),
      body: AsyncStateView<List<ProjectTask>>(
        value: tasksAsync,
        onRetry: () async => ref.invalidate(projectTasksProvider(projectId)),
        data: (context, tasks) {
          ProjectTask? task;
          for (final t in tasks) {
            if (t.id == taskId) {
              task = t;
              break;
            }
          }
          if (task == null) {
            return const EmptyStateView(
              message: 'Görev bulunamadı.',
              icon: Icons.checklist_outlined,
            );
          }
          return _TaskDetailBody(projectId: projectId, task: task);
        },
      ),
    );
  }
}

class _TaskDetailBody extends ConsumerWidget {
  const _TaskDetailBody({required this.projectId, required this.task});
  final String projectId;
  final ProjectTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canUpdate =
        user == null ||
        user.permissions.isEmpty ||
        user.hasPermission('projects.tasks.update');
    final projectAsync = ref.watch(projectDetailProvider(projectId));
    final projectName = projectAsync.maybeWhen(
      data: (p) => p.name,
      orElse: () => '—',
    );

    void refreshAll() {
      ref.invalidate(projectTasksProvider(projectId));
      invalidateTaskLists(ref);
      ref.invalidate(taskUpdatesProvider((projectId: projectId, taskId: task.id)));
      ref.invalidate(projectOperationsSummaryProvider(projectId));
    }

    return RefreshIndicator(
      onRefresh: () async => refreshAll(),
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              StatusRegistry.build(task.status, StatusRegistry.task),
              StatusRegistry.build(task.priority, StatusRegistry.taskPriority),
            ],
          ),
          if (task.isOverdue) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: AppColors.danger,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  'Vadesi geçmiş',
                  style: AppTypography.metadata.copyWith(
                    color: AppColors.danger,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          _TaskActionsBar(
            projectId: projectId,
            task: task,
            canUpdate: canUpdate,
            onChanged: refreshAll,
          ),
          const SizedBox(height: AppSpacing.xs),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title,
                  style: AppTypography.pageTitle.copyWith(
                    fontSize: 17,
                    decoration: task.status == ProjectTask.statusCompleted
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
                if (task.description.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(task.description, style: AppTypography.body),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          const AppSectionHeader(title: 'Bağlam'),
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            child: Column(
              children: [
                _Row('Proje', projectName),
                _Row(
                  'Atanan Kişi',
                  task.assignedName.isNotEmpty ? task.assignedName : 'Atanmadı',
                ),
                _Row(
                  'Vade Tarihi',
                  task.dueDate != null ? Formatters.date(task.dueDate) : '-',
                ),
                if (task.completedAt != null)
                  _Row('Tamamlanma', Formatters.dateTime(task.completedAt)),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _TaskUpdatesSection(projectId: projectId, taskId: task.id),
        ],
      ),
    );
  }
}

/// Göreve yazılan notlar (en yeni önce): kim, ne zaman, ne yazdı, durumu
/// neyden neye çevirdi. Yönetici görevi buradan takip eder.
class _TaskUpdatesSection extends ConsumerWidget {
  const _TaskUpdatesSection({required this.projectId, required this.taskId});
  final String projectId;
  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (projectId: projectId, taskId: taskId);
    final updatesAsync = ref.watch(taskUpdatesProvider(key));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSectionHeader(title: 'Notlar'),
        const SizedBox(height: AppSpacing.sm),
        AsyncStateView<List<TaskUpdate>>(
          value: updatesAsync,
          onRetry: () async => ref.invalidate(taskUpdatesProvider(key)),
          data: (context, updates) {
            if (updates.isEmpty) {
              return AppCard(
                child: Text(
                  'Henüz not yok. Görevi alan kişi "Bilgi Ver" ile ne yaptığını yazar.',
                  style: AppTypography.body.copyWith(color: AppColors.textMuted),
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final u in updates) _TaskUpdateTile(update: u)],
            );
          },
        ),
      ],
    );
  }
}

class _TaskUpdateTile extends StatelessWidget {
  const _TaskUpdateTile({required this.update});
  final TaskUpdate update;

  String _label(String status) => StatusRegistry.task[status]?.$1 ?? status;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      key: Key('gorev-notu-${update.id}'),
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  update.authorName.isNotEmpty ? update.authorName : 'Kullanıcı',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.body.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(Formatters.dateTime(update.createdAt), style: AppTypography.helper),
            ],
          ),
          if (update.changesStatus) ...[
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                const Icon(Icons.swap_horiz, size: 16, color: AppColors.textMuted),
                const SizedBox(width: AppSpacing.xs),
                Flexible(
                  child: Text(
                    '${_label(update.statusFrom)} → ${_label(update.statusTo)}',
                    style: AppTypography.metadata.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ],
          if (update.body.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(update.body, style: AppTypography.body),
          ],
        ],
      ),
    );
  }
}

/// Düzenle + Tamamla `projects.tasks.update` gerektirir ("oluştur"dan AYRI
/// bir izin -- field rolü örneğin update alır ama create ALMAZ, bkz. Phase
/// 1: backend migration 0034 rol matrisi). "Yeniden aç" AYRI bir aksiyon
/// DEĞİLDİR -- Düzenle ekranındaki durum seçicisiyle yapılır (backend'de
/// zaten sabit bir geçiş kısıtı yok).
class _TaskActionsBar extends ConsumerStatefulWidget {
  const _TaskActionsBar({
    required this.projectId,
    required this.task,
    required this.canUpdate,
    required this.onChanged,
  });

  final String projectId;
  final ProjectTask task;
  final bool canUpdate;
  final VoidCallback onChanged;

  @override
  ConsumerState<_TaskActionsBar> createState() => _TaskActionsBarState();
}

class _TaskActionsBarState extends ConsumerState<_TaskActionsBar> {
  bool _busy = false;

  Future<void> _complete() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(projectsRepositoryProvider)
          .completeTask(widget.projectId, widget.task.id);
      widget.onChanged();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _giveInfo() async {
    final result = await showTaskUpdateSheet(context, projectId: widget.projectId, task: widget.task);
    if (result == null || !mounted) return;
    widget.onChanged();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Bilgi gönderildi.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.canUpdate) return const SizedBox.shrink();
    final open = widget.task.status != ProjectTask.statusCompleted;
    // Düğmeler Size.fromHeight(48) ile tam genişlik ister: yan yana
    // olanlar Expanded içinde.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: PrimaryButton(
                key: const Key('gorev-bilgi-ver'),
                icon: Icons.chat_bubble_outline,
                label: 'Bilgi Ver',
                onPressed: _busy ? null : _giveInfo,
              ),
            ),
            if (open) ...[
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: SecondaryButton(
                  icon: Icons.check_circle_outline,
                  label: 'Tamamla',
                  loading: _busy,
                  onPressed: _complete,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        SecondaryButton(
          icon: Icons.edit_outlined,
          label: 'Düzenle',
          onPressed: _busy
              ? null
              : () => context.push(
                  '/projeler/${widget.projectId}/gorevler/${widget.task.id}/duzenle',
                ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: AppTypography.metadata),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.body.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
