import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../data/projects_providers.dart';
import '../domain/project.dart';

Future<ProjectNote?> showNoteFormSheet(BuildContext context, String projectId) {
  return showModalBottomSheet<ProjectNote>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _NoteFormSheet(projectId: projectId),
  );
}

class _NoteFormSheet extends ConsumerStatefulWidget {
  const _NoteFormSheet({required this.projectId});
  final String projectId;

  @override
  ConsumerState<_NoteFormSheet> createState() => _NoteFormSheetState();
}

class _NoteFormSheetState extends ConsumerState<_NoteFormSheet> {
  final _formKey = GlobalKey<FormState>();
  final _contentController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final note = await ref.read(projectsRepositoryProvider).createNote(
            widget.projectId,
            content: _contentController.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(note);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.xl,
        right: AppSpacing.xl,
        top: AppSpacing.xl,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Not Ekle', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
            const SizedBox(height: AppSpacing.lg),
            AppFormSection(
              title: 'Not',
              children: [
                TextFormField(
                  controller: _contentController,
                  decoration: const InputDecoration(
                    labelText: 'Not',
                    alignLabelWithHint: true,
                  ),
                  minLines: 4,
                  maxLines: 8,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Not boş olamaz';
                    return null;
                  },
                ),
              ],
            ),
            if (_error != null) ...[
              Text(_error!, style: AppTypography.error),
              const SizedBox(height: AppSpacing.md),
            ],
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
                  child: PrimaryButton(label: 'Kaydet', loading: _submitting, onPressed: _submit),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
