import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
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
                ButtonSegment(value: ProjectTask.statusCompleted, label: Text('Tamamlanan')),
              ],
              selected: {_statusMode},
              onSelectionChanged: (s) => setState(() => _statusMode = s.first),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 20),
                hintText: 'Başlık veya proje ara',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilterChip(
                  label: const Text('Yalnızca gecikmiş'),
                  selected: _overdueOnly,
                  onSelected: (v) => setState(() => _overdueOnly = v),
                ),
                ...const [
                  (ProjectTask.priorityUrgent, 'Acil'),
                  (ProjectTask.priorityHigh, 'Yüksek'),
                  (ProjectTask.priorityNormal, 'Normal'),
                  (ProjectTask.priorityLow, 'Düşük'),
                ].map((p) => FilterChip(
                      label: Text(p.$2),
                      selected: _priorityFilter == p.$1,
                      onSelected: (v) => setState(() => _priorityFilter = v ? p.$1 : null),
                    )),
              ],
            ),
            const SizedBox(height: 12),
            AsyncStateView(
              value: tasksAsync,
              onRetry: () async => ref.invalidate(myTasksProvider(_statusMode)),
              data: (context, allItems) {
                final projects = <String, String>{};
                for (final item in allItems) {
                  projects[item.$2] = item.$3;
                }
                final items = allItems
                    .where((item) => myTaskMatchesFilters(
                          item.$1,
                          item.$2,
                          item.$3,
                          overdueOnly: _overdueOnly,
                          priority: _priorityFilter,
                          projectFilter: _projectFilter,
                          searchQuery: _searchController.text,
                        ))
                    .toList();

                if (allItems.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('Görev yok.', style: TextStyle(color: Colors.grey))),
                  );
                }
                if (items.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('Bu filtreye uyan görev yok.', style: TextStyle(color: Colors.grey))),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (projects.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: DropdownButtonFormField<String>(
                          initialValue: _projectFilter ?? '',
                          decoration: const InputDecoration(labelText: 'Proje', isDense: true),
                          items: [
                            const DropdownMenuItem(value: '', child: Text('Tüm projeler')),
                            ...projects.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))),
                          ],
                          onChanged: (v) => setState(() => _projectFilter = (v == null || v.isEmpty) ? null : v),
                        ),
                      ),
                    ...items.map((item) {
                      final (task, projectId, projectName) = item;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          onTap: () => context.push('/projeler/$projectId/gorevler/${task.id}'),
                          leading: Checkbox(
                            value: task.status == ProjectTask.statusCompleted,
                            onChanged: task.status == ProjectTask.statusCompleted
                                ? null
                                : (_) async {
                                    await ref.read(projectsRepositoryProvider).completeTask(projectId, task.id);
                                    ref.invalidate(myTasksProvider(_statusMode));
                                  },
                          ),
                          title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(projectName, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              StatusRegistry.build(task.priority, StatusRegistry.taskPriority),
                              const SizedBox(height: 4),
                              if (task.dueDate != null)
                                Text(
                                  Formatters.date(task.dueDate),
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: task.isOverdue ? AppColors.danger : AppColors.textMuted,
                                    fontWeight: task.isOverdue ? FontWeight.w700 : FontWeight.w400,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    }),
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
