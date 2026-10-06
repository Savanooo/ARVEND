import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/app_spacing.dart';
import '../../../../../core/theme/app_typography.dart';
import '../../../../../core/widgets/app_buttons.dart';
import '../../../../../core/widgets/unsaved_changes_scope.dart';
import '../../data/budget_providers.dart';
import '../../domain/budget.dart';
import '../widgets/budget_ui.dart';
import '../../../../../core/widgets/app_sheet.dart';

/// WBS düğümü ekle (kök ya da [parent] altına) / yeniden adlandır
/// ([existing]) -- web `NewNodeRow`/`RenameRow` alanları: Kod, Ad. Ağaç
/// konumu (parent) sonradan DEĞİŞTİRİLEMEZ; sıra korunur. Kaydedilen düğüm
/// döner.
Future<WbsNode?> showWbsNodeSheet(
  BuildContext context, {
  required String projectId,
  WbsNode? existing,
  WbsNode? parent,
}) {
  return showAppSheet<WbsNode>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => WbsNodeSheet(projectId: projectId, existing: existing, parent: parent),
  );
}

class WbsNodeSheet extends ConsumerStatefulWidget {
  const WbsNodeSheet({super.key, required this.projectId, this.existing, this.parent});

  final String projectId;
  final WbsNode? existing;
  final WbsNode? parent;

  @override
  ConsumerState<WbsNodeSheet> createState() => _WbsNodeSheetState();
}

class _WbsNodeSheetState extends ConsumerState<WbsNodeSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _code = TextEditingController(text: widget.existing?.code ?? '');
  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  String get _title {
    if (widget.existing != null) return 'Düğümü Yeniden Adlandır';
    return widget.parent != null ? 'Alt Düğüm Ekle' : 'Kök Düğüm Ekle';
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final existing = widget.existing;
    final input = WbsNodeInput(
      parentId: existing?.parentId ?? widget.parent?.id,
      code: _code.text.trim(),
      name: _name.text.trim(),
      sortOrder: existing?.sortOrder ?? 0,
    );
    setState(() {
      _submitting = true;
      _error = null;
    });
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final repo = container.read(budgetRepositoryProvider);
      final saved = existing == null
          ? await repo.createWbsNode(widget.projectId, input)
          : await repo.updateWbsNode(widget.projectId, existing.id, input);
      invalidateBudgetModule(container.invalidate, widget.projectId);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) setState(() => _error = budgetErrorText(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final parent = widget.parent;
    return UnsavedChangesScope(
      busy: _submitting,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_title, style: AppTypography.pageTitle.copyWith(fontSize: 17)),
                if (parent != null) ...[
                  const SizedBox(height: 2),
                  Text('Üst düğüm: ${parent.label}', style: AppTypography.metadata),
                ],
                const SizedBox(height: AppSpacing.lg),
                TextFormField(
                  key: const ValueKey('wbs-code'),
                  controller: _code,
                  autofocus: widget.existing == null,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [LengthLimitingTextInputFormatter(30)],
                  decoration: const InputDecoration(labelText: 'Kod *', hintText: 'ör. 01.02'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'WBS kodu zorunludur' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  key: const ValueKey('wbs-name'),
                  controller: _name,
                  inputFormatters: [LengthLimitingTextInputFormatter(150)],
                  decoration: const InputDecoration(labelText: 'Ad *', hintText: 'ör. Kaba İnşaat'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'WBS adı zorunludur' : null,
                ),
                const SizedBox(height: AppSpacing.lg),
                if (_error != null) ...[
                  Text(_error!, style: AppTypography.error),
                  const SizedBox(height: AppSpacing.md),
                ],
                PrimaryButton(
                  label: widget.existing == null ? 'Ekle' : 'Kaydet',
                  loading: _submitting,
                  onPressed: _submit,
                ),
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                  child: const Text('Vazgeç'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
