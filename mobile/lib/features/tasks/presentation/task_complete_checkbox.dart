import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../projects/data/projects_providers.dart';
import '../../projects/domain/project.dart';
import '../data/tasks_providers.dart';

/// Görev listelerindeki "tamamla" onay kutusu (Görevler sekmesi ve proje >
/// Operasyon > Görevler). Eskiden hata yutuluyordu (kutu sessizce boş
/// kalıyordu) ve istek sürerken ikinci dokunuş ikinci bir istek atıyordu:
/// şimdi istek sürerken kutunun yerinde gösterge döner (dokunuş kapalı),
/// başarısızlıkta backend'in Türkçe mesajı gösterilir.
class TaskCompleteCheckbox extends ConsumerStatefulWidget {
  const TaskCompleteCheckbox({super.key, required this.projectId, required this.task});

  final String projectId;
  final ProjectTask task;

  @override
  ConsumerState<TaskCompleteCheckbox> createState() => _TaskCompleteCheckboxState();
}

class _TaskCompleteCheckboxState extends ConsumerState<TaskCompleteCheckbox> {
  bool _busy = false;

  Future<void> _complete() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(projectsRepositoryProvider).completeTask(widget.projectId, widget.task.id);
      ref.invalidate(projectTasksProvider(widget.projectId));
      ref.invalidate(projectOperationsSummaryProvider(widget.projectId));
      invalidateTaskLists(ref);
    } on ApiException catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const SizedBox(
        width: 48,
        height: 48,
        child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    final done = widget.task.status == ProjectTask.statusCompleted;
    return Checkbox(
      value: done,
      onChanged: done ? null : (_) => _complete(),
    );
  }
}
