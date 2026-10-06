import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_form_section.dart';
import '../../../../core/widgets/unsaved_changes_scope.dart';
import '../data/contract_co_repository.dart';
import '../data/contract_co_providers.dart';
import '../domain/project_change_order.dart';
import 'widgets/contract_co_ui.dart';
import '../../../../core/widgets/app_sheet.dart';

/// "Mail Gönder" (web ChangeOrderCard e-posta formu): Kime (müşteri
/// e-postasıyla dolu gelir), Konu ve Mesaj opsiyonel -- boşsa sunucu
/// varsayılan konu/metni kullanır ve paylaşım linkini mesajın sonuna
/// ekler. Gönderildiyse `true`.
///
/// SMTP hatası kullanıcıya sunucunun mesajıyla gösterilir; deneme her
/// durumda (başarılı/başarısız) sunucuda ek işin olaylarına yazılır.
Future<bool?> showChangeOrderEmailSheet(
  BuildContext context, {
  required String projectId,
  required ProjectChangeOrder changeOrder,
  String defaultTo = '',
}) {
  return showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _ChangeOrderEmailSheet(projectId: projectId, changeOrder: changeOrder, defaultTo: defaultTo),
  );
}

class _ChangeOrderEmailSheet extends ConsumerStatefulWidget {
  const _ChangeOrderEmailSheet({required this.projectId, required this.changeOrder, required this.defaultTo});

  final String projectId;
  final ProjectChangeOrder changeOrder;
  final String defaultTo;

  @override
  ConsumerState<_ChangeOrderEmailSheet> createState() => _ChangeOrderEmailSheetState();
}

class _ChangeOrderEmailSheetState extends ConsumerState<_ChangeOrderEmailSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _to = TextEditingController(text: widget.defaultTo);
  final _subject = TextEditingController();
  final _message = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _to.dispose();
    _subject.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final ContractCoRepository repo = ref.read(contractCoRepositoryProvider);
    try {
      await repo.sendChangeOrderEmail(
        widget.projectId,
        widget.changeOrder.id,
        ChangeOrderEmailInput(to: _to.text.trim(), subject: _subject.text.trim(), message: _message.text.trim()),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = contractCoErrorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesScope(
      busy: _submitting,
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          top: AppSpacing.xl,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
        ),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Mail Gönder', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
                const SizedBox(height: 2),
                Text(
                  '${widget.changeOrder.changeOrderNo} — ${widget.changeOrder.title}',
                  style: AppTypography.metadata,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.lg),
                AppFormSection(
                  title: 'E-posta',
                  subtitle: 'Paylaşım linki mesajın sonuna eklenir.',
                  children: [
                    TextFormField(
                      controller: _to,
                      decoration: const InputDecoration(labelText: 'Kime'),
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Alıcı e-posta adresi zorunludur' : null,
                    ),
                    TextFormField(
                      controller: _subject,
                      decoration: const InputDecoration(labelText: 'Konu (opsiyonel)'),
                    ),
                    TextFormField(
                      controller: _message,
                      decoration: const InputDecoration(labelText: 'Mesaj (opsiyonel)', alignLabelWithHint: true),
                      minLines: 3,
                      maxLines: 6,
                      textCapitalization: TextCapitalization.sentences,
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
                        label: 'Vazgeç',
                        onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: PrimaryButton(
                        label: 'Gönder',
                        icon: Icons.send_outlined,
                        loading: _submitting,
                        onPressed: _submit,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
