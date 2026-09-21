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
      ref.invalidate(myTasksProvider);
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

  @override
  Widget build(BuildContext context) {
    if (!widget.canUpdate) return const SizedBox.shrink();
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        SecondaryButton(
          icon: Icons.edit_outlined,
          label: 'Düzenle',
          onPressed: _busy
              ? null
              : () => context.push(
                  '/projeler/${widget.projectId}/gorevler/${widget.task.id}/duzenle',
                ),
        ),
        if (widget.task.status != ProjectTask.statusCompleted)
          PrimaryButton(
            icon: Icons.check_circle_outline,
            label: 'Tamamla',
            loading: _busy,
            onPressed: _complete,
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
