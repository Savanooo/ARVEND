import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
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
/// atar) -- var olmayan bir alan İCAT EDİLMEZ.
class TaskDetailScreen extends ConsumerWidget {
  const TaskDetailScreen({super.key, required this.projectId, required this.taskId});
  final String projectId;
  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasksAsync = ref.watch(projectTasksProvider(projectId));

    return Scaffold(
      appBar: AppBar(title: const Text('Görev')),
      body: tasksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _RetryView(error: e, onRetry: () => ref.invalidate(projectTasksProvider(projectId))),
        data: (tasks) {
          ProjectTask? task;
          for (final t in tasks) {
            if (t.id == taskId) {
              task = t;
              break;
            }
          }
          if (task == null) {
            return const Center(child: Text('Görev bulunamadı.', style: TextStyle(color: Colors.grey)));
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
    final canUpdate = user == null || user.permissions.isEmpty || user.hasPermission('projects.tasks.update');

    void refreshAll() {
      ref.invalidate(projectTasksProvider(projectId));
      ref.invalidate(myTasksProvider);
      ref.invalidate(projectOperationsSummaryProvider(projectId));
    }

    return RefreshIndicator(
      onRefresh: () async => refreshAll(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              StatusRegistry.build(task.status, StatusRegistry.task),
              StatusRegistry.build(task.priority, StatusRegistry.taskPriority),
            ],
          ),
          if (task.isOverdue) ...[
            const SizedBox(height: 8),
            Row(
              children: const [
                Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.danger),
                SizedBox(width: 4),
                Text('Vadesi geçmiş', style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700, fontSize: 12.5)),
              ],
            ),
          ],
          const SizedBox(height: 12),
          _TaskActionsBar(projectId: projectId, task: task, canUpdate: canUpdate, onChanged: refreshAll),
          const SizedBox(height: 4),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        decoration: task.status == ProjectTask.statusCompleted ? TextDecoration.lineThrough : null,
                      )),
                  if (task.description.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(task.description),
                  ],
                  const Divider(height: 20),
                  _Row('Atanan Kişi', task.assignedName.isNotEmpty ? task.assignedName : 'Atanmadı'),
                  _Row('Vade Tarihi', task.dueDate != null ? Formatters.date(task.dueDate) : '-'),
                  if (task.completedAt != null) _Row('Tamamlanma', Formatters.dateTime(task.completedAt)),
                ],
              ),
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
  const _TaskActionsBar({required this.projectId, required this.task, required this.canUpdate, required this.onChanged});

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
      await ref.read(projectsRepositoryProvider).completeTask(widget.projectId, widget.task.id);
      widget.onChanged();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.canUpdate) return const SizedBox.shrink();
    final buttons = <Widget>[
      OutlinedButton.icon(
        icon: const Icon(Icons.edit_outlined, size: 18),
        label: const Text('Düzenle'),
        onPressed: _busy
            ? null
            : () => context.push('/projeler/${widget.projectId}/gorevler/${widget.task.id}/duzenle'),
      ),
    ];
    if (widget.task.status != ProjectTask.statusCompleted) {
      buttons.add(FilledButton.tonalIcon(
        icon: const Icon(Icons.check_circle_outline, size: 18),
        label: const Text('Tamamla'),
        onPressed: _busy ? null : _complete,
      ));
    }
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _RetryView extends StatelessWidget {
  const _RetryView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = error is ApiException ? (error as ApiException).message : 'Beklenmeyen bir hata oluştu.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.danger, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textMuted)),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Tekrar Dene')),
          ],
        ),
      ),
    );
  }
}
