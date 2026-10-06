import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/status_badge.dart';
import '../../projects/data/projects_providers.dart';
import '../../projects/domain/project.dart';
import '../../../core/widgets/app_sheet.dart';

/// "Bilgi Ver": göreve not (isteğe bağlı durum değişikliğiyle). Görevi
/// alan kişi ne yaptığını buradan yazar; sunucu görevi verene ve proje
/// yöneticisine bildirim düşer (POST /projects/{id}/tasks/{taskId}/updates).
/// Kaydedilirse (not, görevin son hali) döner.
Future<(TaskUpdate, ProjectTask)?> showTaskUpdateSheet(
  BuildContext context, {
  required String projectId,
  required ProjectTask task,
}) {
  return showAppSheet<(TaskUpdate, ProjectTask)>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => TaskUpdateSheet(projectId: projectId, task: task),
  );
}

/// Sunucudaki sınır (maxTaskUpdateRunes) ile aynı.
const kTaskUpdateMaxLength = 2000;

class TaskUpdateSheet extends ConsumerStatefulWidget {
  const TaskUpdateSheet({super.key, required this.projectId, required this.task});
  final String projectId;
  final ProjectTask task;

  @override
  ConsumerState<TaskUpdateSheet> createState() => _TaskUpdateSheetState();
}

class _TaskUpdateSheetState extends ConsumerState<TaskUpdateSheet> {
  final _bodyController = TextEditingController();

  /// null = durum değişmesin.
  String? _status;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final body = _bodyController.text.trim();
    if (body.isEmpty && _status == null) {
      setState(() => _error = 'Bir not yaz ya da durumu değiştir.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(projectsRepositoryProvider)
          .addTaskUpdate(widget.projectId, widget.task.id, body: body, status: _status);
      if (mounted) Navigator.of(context).pop(result);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.task.status;
    final choices = [
      for (final s in const [
        ProjectTask.statusTodo,
        ProjectTask.statusInProgress,
        ProjectTask.statusCompleted,
      ])
        if (s != current) s,
    ];
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.xl,
        right: AppSpacing.xl,
        top: AppSpacing.xl,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Bilgi Ver', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
            const SizedBox(height: AppSpacing.xs),
            Text(
              widget.task.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.metadata,
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              key: const Key('gorev-not'),
              controller: _bodyController,
              decoration: const InputDecoration(
                labelText: 'Not',
                hintText: 'Ne yapıldı, ne kaldı, ne lazım?',
                alignLabelWithHint: true,
              ),
              minLines: 3,
              maxLines: 8,
              maxLength: kTaskUpdateMaxLength,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text('Durum', style: AppTypography.metadata),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                ChoiceChip(
                  label: Text('Değişmesin (${StatusRegistry.task[current]?.$1 ?? current})'),
                  selected: _status == null,
                  onSelected: (_) => setState(() => _status = null),
                ),
                for (final s in choices)
                  ChoiceChip(
                    key: Key('gorev-durum-$s'),
                    label: Text(StatusRegistry.task[s]?.$1 ?? s),
                    selected: _status == s,
                    onSelected: (_) => setState(() => _status = s),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                const Icon(Icons.notifications_none, size: 16, color: AppColors.textMuted),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'Görevi veren ve proje yöneticisi bildirim alır.',
                    style: AppTypography.helper.copyWith(color: AppColors.textMuted),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(_error!, style: AppTypography.error),
            ],
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: SecondaryButton(
                    label: 'İptal',
                    onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: PrimaryButton(
                    key: const Key('gorev-not-gonder'),
                    label: 'Gönder',
                    loading: _submitting,
                    onPressed: _submit,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
