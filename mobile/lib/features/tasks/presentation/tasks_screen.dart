import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../../projects/data/projects_providers.dart';
import '../data/tasks_providers.dart';

/// Global görevler — GET /tasks/mine (tek sorgu).
class TasksScreen extends ConsumerWidget {
  const TasksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasksAsync = ref.watch(myTasksProvider);

    return Scaffold(
      appBar: buildAppBar('Görevler'),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(myTasksProvider),
        child: AsyncStateView(
          value: tasksAsync,
          onRetry: () async => ref.invalidate(myTasksProvider),
          isEmpty: (l) => l.isEmpty,
          emptyBuilder: (_) => const EmptyStateView(message: 'Açık görev yok.'),
          data: (context, items) => ListView.separated(
            padding: kScreenPadding,
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final (task, projectId, projectName) = items[i];
              return Card(
                child: ListTile(
                  onTap: () => context.push('/projeler/$projectId'),
                  leading: Checkbox(
                    value: false,
                    onChanged: (_) async {
                      await ref.read(projectsRepositoryProvider).completeTask(projectId, task.id);
                      ref.invalidate(myTasksProvider);
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
            },
          ),
        ),
      ),
    );
  }
}
