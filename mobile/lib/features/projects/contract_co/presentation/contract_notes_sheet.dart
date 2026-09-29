import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/unsaved_changes_scope.dart';
import '../data/contract_co_providers.dart';
import '../domain/project_contract.dart';
import 'widgets/contract_co_ui.dart';

/// Sözleşmenin dahili notunu düzenler (`PUT .../contract/notes`) --
/// ticari OLMAYAN alan, taslak VE aktifte açık (web "Notu Kaydet").
/// Kaydedilirse güncel sözleşme döner, vazgeçilirse `null`.
Future<ProjectContract?> showContractNotesSheet(
  BuildContext context, {
  required String projectId,
  required String initial,
}) {
  return showModalBottomSheet<ProjectContract>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Sürükleyerek kapatma PopScope'u (UnsavedChangesScope) atlar: kayıt
    // sürerken sayfa kapanıp sonuç kaybolmasın.
    enableDrag: false,
    builder: (_) => _ContractNotesSheet(projectId: projectId, initial: initial),
  );
}

class _ContractNotesSheet extends ConsumerStatefulWidget {
  const _ContractNotesSheet({required this.projectId, required this.initial});

  final String projectId;
  final String initial;

  @override
  ConsumerState<_ContractNotesSheet> createState() => _ContractNotesSheetState();
}

class _ContractNotesSheetState extends ConsumerState<_ContractNotesSheet> {
  late final _controller = TextEditingController(text: widget.initial);
  bool _submitting = false;
  String? _error;

  bool get _dirty => _controller.text.trim() != widget.initial.trim();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final updated =
          await ref.read(contractCoRepositoryProvider).updateContractNotes(widget.projectId, _controller.text.trim());
      if (mounted) Navigator.of(context).pop(updated);
    } catch (e) {
      if (mounted) setState(() => _error = contractCoErrorText(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesScope(
      dirty: _dirty,
      busy: _submitting,
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          top: AppSpacing.xl,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Dahili Not', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
            const SizedBox(height: 2),
            const Text('Yalnızca ekip görür; müşteriyle paylaşılmaz.', style: AppTypography.metadata),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 4,
              maxLines: 10,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Dahili Not (yalnızca ekip görür)', alignLabelWithHint: true),
              onChanged: (_) => setState(() {}),
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
                    label: 'Vazgeç',
                    onPressed: _submitting ? null : () => Navigator.of(context).maybePop(),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: PrimaryButton(label: 'Notu Kaydet', loading: _submitting, onPressed: _submit),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
