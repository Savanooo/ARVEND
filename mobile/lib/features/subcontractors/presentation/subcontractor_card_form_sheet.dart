import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_sheet.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../../suppliers/domain/supplier.dart';
import '../data/subcontractors_repository.dart';

/// Yeni taşeron kartı (POST /subcontractors). Kod sunucuda verilir
/// (TSR-NNNN); ad zorunlu, gerisi isteğe bağlı. IBAN yalnızca yazılır,
/// hiçbir ekranda geri gösterilmez. [initialName]: projedeki formdan
/// "Yeni taşeron" ile gelince yazılmış ad.
Future<OrganizationSupplier?> showSubcontractorCardFormSheet(BuildContext context, {String initialName = ''}) {
  return showAppSheet<OrganizationSupplier>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _SubcontractorCardFormSheet(initialName: initialName),
  );
}

class _SubcontractorCardFormSheet extends ConsumerStatefulWidget {
  const _SubcontractorCardFormSheet({required this.initialName});

  final String initialName;

  @override
  ConsumerState<_SubcontractorCardFormSheet> createState() => _SubcontractorCardFormSheetState();
}

class _SubcontractorCardFormSheetState extends ConsumerState<_SubcontractorCardFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initialName);
  final _company = TextEditingController();
  final _phone = TextEditingController();
  final _specialty = TextEditingController();
  final _taxNumber = TextEditingController();
  final _iban = TextEditingController();
  final _notes = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _company, _phone, _specialty, _taxNumber, _iban, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final card = await ref.read(subcontractorsRepositoryProvider).create(
            name: _name.text.trim(),
            companyName: _company.text.trim(),
            phone: _phone.text.trim(),
            specialty: _specialty.text.trim(),
            taxNumber: _taxNumber.text.trim(),
            iban: _iban.text.replaceAll(' ', '').trim(),
            notes: _notes.text.trim(),
          );
      ref.invalidate(subcontractorCardsProvider);
      if (mounted) Navigator.of(context).pop(card);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.isForbidden ? 'Taşeron eklemek için yetkin yok.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesScope(
      busy: _busy,
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
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Yeni Taşeron', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
                const SizedBox(height: AppSpacing.xs),
                const Text(
                  'Taşeronu bir kez gir; projelerde listeden seç, proje dışı ödemeleri de buradan yap.',
                  style: AppTypography.helper,
                ),
                const SizedBox(height: AppSpacing.lg),
                AppFormSection(
                  title: 'Taşeron Bilgileri',
                  children: [
                    TextFormField(
                      key: const ValueKey('taseron-ad'),
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      maxLength: 200,
                      decoration: const InputDecoration(labelText: 'Ad soyad / unvan', counterText: ''),
                      validator: (v) => (v ?? '').trim().isEmpty ? 'Taşeron adı gerekli' : null,
                    ),
                    TextFormField(
                      controller: _specialty,
                      maxLength: 100,
                      decoration: const InputDecoration(
                        labelText: 'Branş (opsiyonel)',
                        hintText: 'Elektrik, sıva, fayans…',
                        counterText: '',
                      ),
                    ),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      maxLength: 30,
                      decoration: const InputDecoration(labelText: 'Telefon (opsiyonel)', counterText: ''),
                    ),
                    TextFormField(
                      controller: _company,
                      maxLength: 200,
                      decoration: const InputDecoration(labelText: 'Firma adı (opsiyonel)', counterText: ''),
                    ),
                  ],
                ),
                AppFormSection(
                  title: 'Ödeme Bilgileri (opsiyonel)',
                  children: [
                    TextFormField(
                      controller: _iban,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 40,
                      decoration: const InputDecoration(labelText: 'IBAN', counterText: ''),
                    ),
                    TextFormField(
                      controller: _taxNumber,
                      keyboardType: TextInputType.number,
                      maxLength: 30,
                      decoration: const InputDecoration(labelText: 'Vergi / TC kimlik no', counterText: ''),
                    ),
                    TextFormField(
                      controller: _notes,
                      minLines: 1,
                      maxLines: 3,
                      decoration: const InputDecoration(labelText: 'Not'),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  Text(_error!, style: AppTypography.error),
                  const SizedBox(height: AppSpacing.md),
                ],
                PrimaryButton(
                  key: const ValueKey('taseron-kaydet'),
                  label: 'Taşeronu Kaydet',
                  loading: _busy,
                  onPressed: _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
