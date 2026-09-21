import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_filter_bar.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../../projects/data/projects_providers.dart';
import '../../projects/domain/project.dart';
import '../data/tasks_providers.dart';
import '../domain/task_filters.dart';

/// Global görevler — GET /tasks/mine (tek sorgu, proje döngüsü YOK). Durum
/// filtresi backend'e GİDER (`status` query param, sunucu tarafında
/// filtrelenir); gecikme/öncelik/proje/arama filtreleri ZATEN çekilmiş TEK
/// listenin üzerinde istemci tarafında uygulanır -- her ikisi de YENİ bir
/// ağ isteği İCAT ETMEZ.
class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});

  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  String _statusMode = 'open';
  bool _overdueOnly = false;
  String? _priorityFilter;
  String? _projectFilter;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tasksAsync = ref.watch(myTasksProvider(_statusMode));

    return Scaffold(
      appBar: buildAppBar('Görevlerim'),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(myTasksProvider(_statusMode)),
        child: ListView(
          padding: kScreenPadding,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'open', label: Text('Açık')),
                ButtonSegment(value: 'all', label: Text('Tümü')),
                ButtonSegment(
                  value: ProjectTask.statusCompleted,
                  label: Text('Tamamlanan'),
                ),
              ],
              selected: {_statusMode},
              onSelectionChanged: (s) => setState(() => _statusMode = s.first),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 20),
                hintText: 'Başlık veya proje ara',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppFilterBar(
              wrap: true,
              chips: [
                AppFilterChipData(
                  label: 'Yalnızca gecikmiş',
                  selected: _overdueOnly,
                  onTap: () => setState(() => _overdueOnly = !_overdueOnly),
                ),
                for (final p in const [
                  (ProjectTask.priorityUrgent, 'Acil'),
                  (ProjectTask.priorityHigh, 'Yüksek'),
                  (ProjectTask.priorityNormal, 'Normal'),
                  (ProjectTask.priorityLow, 'Düşük'),
                ])
                  AppFilterChipData(
                    label: p.$2,
                    selected: _priorityFilter == p.$1,
                    onTap: () => setState(
                      () => _priorityFilter = _priorityFilter == p.$1
                          ? null
                          : p.$1,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AsyncStateView(
              value: tasksAsync,
              onRetry: () async => ref.invalidate(myTasksProvider(_statusMode)),
              data: (context, allItems) {
                final projects = <String, String>{};
                for (final item in allItems) {
                  projects[item.$2] = item.$3;
                }
                final items = allItems
                    .where(
                      (item) => myTaskMatchesFilters(
                        item.$1,
                        item.$2,
                        item.$3,
                        overdueOnly: _overdueOnly,
                        priority: _priorityFilter,
                        projectFilter: _projectFilter,
                        searchQuery: _searchController.text,
                      ),
                    )
                    .toList();

                if (allItems.isEmpty) {
                  return const EmptyStateView(
                    message: 'Görev yok.',
                    icon: Icons.checklist_outlined,
                  );
                }
                if (items.isEmpty) {
                  return const EmptyStateView(
                    message: 'Bu filtreye uyan görev yok.',
                    icon: Icons.checklist_outlined,
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (projects.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: DropdownButtonFormField<String>(
                          initialValue: _projectFilter ?? '',
                          decoration: const InputDecoration(
                            labelText: 'Proje',
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: '',
                              child: Text('Tüm projeler'),
                            ),
                            ...projects.entries.map(
                              (e) => DropdownMenuItem(
                                value: e.key,
                                child: Text(e.value),
                              ),
                            ),
                          ],
                          onChanged: (v) => setState(
                            () => _projectFilter = (v == null || v.isEmpty)
                                ? null
                                : v,
                          ),
                        ),
                      ),
                    for (final item in items)
                      _TaskRow(item: item, statusMode: _statusMode),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.item, required this.statusMode});
  final ProjectTaskWithProject item;
  final String statusMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (task, projectId, projectName) = item;
    return AppListCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      onTap: () => context.push('/projeler/$projectId/gorevler/${task.id}'),
      leading: Checkbox(
        value: task.status == ProjectTask.statusCompleted,
        onChanged: task.status == ProjectTask.statusCompleted
            ? null
            : (_) async {
                await ref
                    .read(projectsRepositoryProvider)
                    .completeTask(projectId, task.id);
                ref.invalidate(myTasksProvider(statusMode));
              },
      ),
      title: task.title,
      subtitle: projectName,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          StatusRegistry.build(task.priority, StatusRegistry.taskPriority),
          if (task.dueDate != null) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (task.isOverdue) ...[
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 12,
                    color: AppColors.danger,
                  ),
                  const SizedBox(width: 2),
                ],
                Text(
                  Formatters.date(task.dueDate),
                  style: AppTypography.helper.copyWith(
                    color: task.isOverdue
                        ? AppColors.danger
                        : AppColors.textMuted,
                    fontWeight: task.isOverdue
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
