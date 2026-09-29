import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_form_section.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/unsaved_changes_scope.dart';
import '../../data/projects_providers.dart';
import '../contract_co_paths.dart';
import '../data/contract_co_providers.dart';
import '../domain/project_contract.dart';
import 'widgets/contract_co_ui.dart';

/// Sözleşme şartlarını düzenle (`/projeler/:id/sozlesme/duzenle`) -- web
/// ContractSection'ın taslak formu. Yalnızca TASLAK sözleşmede ve
/// `projects.contracts.manage` ile açılır; aktivasyonla bu alanlar kalıcı
/// olarak kilitlenir (sunucu 409 döner). Dahili not ayrı uçtadır (bkz.
/// contract_notes_sheet.dart).
class ContractFormScreen extends ConsumerWidget {
  const ContractFormScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const title = Text('Sözleşme Şartları');
    final auth = ref.watch(authControllerProvider);
    if (isAuthPending(auth)) return const AppPageScaffold(title: title, body: LoadingState());
    final user = auth.valueOrNull;
    if (!user.can(kContractsManagePermission)) {
      return const AppPageScaffold(
        title: title,
        body: NoAccessView(
          message: 'Sözleşme şartlarını düzenleme yetkin yok. Bunun için rolünde "Sözleşme taslağı '
              'oluşturma/düzenleme" izni olmalı.',
        ),
      );
    }
    final contractAsync = ref.watch(projectContractProvider(projectId));
    final project = ref.watch(projectDetailProvider(projectId)).valueOrNull;

    return AppPageScaffold(
      title: title,
      body: contractAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => isForbiddenError(e)
            ? const NoAccessView(message: kContractNoAccessText)
            : ErrorState(error: e, onRetry: () async => ref.invalidate(projectContractProvider(projectId))),
        data: (contract) {
          if (contract == null) {
            return const EmptyStateView(message: 'Bu proje için henüz bir sözleşme yok.');
          }
          if (isProjectLocked(project)) {
            return const Padding(padding: EdgeInsets.all(AppSpacing.lg), child: ReadOnlyNotice(kProjectLockedText));
          }
          if (!contract.termsEditable) {
            return const Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: ReadOnlyNotice(
                'Sözleşme şartları yalnızca taslak durumdayken düzenlenebilir. Aktivasyon sonrası değişiklik '
                'için resmi bir Ek İş gereklidir.',
              ),
            );
          }
          return _ContractForm(projectId: projectId, contract: contract);
        },
      ),
    );
  }
}

class _ContractForm extends ConsumerStatefulWidget {
  const _ContractForm({required this.projectId, required this.contract});

  final String projectId;
  final ProjectContract contract;

  @override
  ConsumerState<_ContractForm> createState() => _ContractFormState();
}

class _ContractFormState extends ConsumerState<_ContractForm> {
  late final _scope = TextEditingController(text: widget.contract.scope);
  late final _payment = TextEditingController(text: widget.contract.paymentTerms);
  late final _retention = TextEditingController(text: widget.contract.retentionTerms);
  late final _advance = TextEditingController(text: widget.contract.advanceTerms);
  late String? _effectiveDate = widget.contract.effectiveDate;
  late String? _plannedCompletionDate = widget.contract.plannedCompletionDate;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _scope.dispose();
    _payment.dispose();
    _retention.dispose();
    _advance.dispose();
    super.dispose();
  }

  bool get _dirty {
    final c = widget.contract;
    return _scope.text.trim() != c.scope ||
        _payment.text.trim() != c.paymentTerms ||
        _retention.text.trim() != c.retentionTerms ||
        _advance.text.trim() != c.advanceTerms ||
        _effectiveDate != c.effectiveDate ||
        _plannedCompletionDate != c.plannedCompletionDate;
  }

  /// Planlanan bitiş yürürlükten önce olamaz (aktivasyonla bu tarihler
  /// kalıcı olarak kilitlenir; backend sırayı denetlemiyor). "YYYY-MM-DD"
  /// dizgeleri sözlük sırasıyla karşılaştırılabilir.
  String? get _dateOrderError {
    final start = _effectiveDate;
    final end = _plannedCompletionDate;
    if (start == null || end == null || start.isEmpty || end.isEmpty) return null;
    return end.compareTo(start) < 0 ? 'Planlanan bitiş tarihi yürürlük tarihinden önce olamaz.' : null;
  }

  Future<void> _submit() async {
    // Hata tarih alanlarının altında zaten görünür; kayıt gönderilmez.
    if (_dateOrderError != null) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final invalidate = ProviderScope.containerOf(context, listen: false).invalidate;
    try {
      await ref.read(contractCoRepositoryProvider).updateContractDraft(
            widget.projectId,
            ContractDraftInput(
              scope: _scope.text.trim(),
              paymentTerms: _payment.text.trim(),
              retentionTerms: _retention.text.trim(),
              advanceTerms: _advance.text.trim(),
              effectiveDate: _effectiveDate,
              plannedCompletionDate: _plannedCompletionDate,
            ),
          );
      invalidate(projectContractProvider(widget.projectId));
      if (!mounted) return;
      setState(() => _submitting = false);
      showContractCoSnack(context, 'Sözleşme şartları kaydedildi.');
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(projectContractPath(widget.projectId));
      }
    } catch (e) {
      // 409: sözleşme bu arada aktifleşti -- ekran kilitli duruma dönsün.
      if (isConflictError(e)) invalidate(projectContractProvider(widget.projectId));
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = contractCoErrorText(e);
      });
    }
  }

  Widget _multiline(TextEditingController controller, String label, {String? hint}) => TextField(
        controller: controller,
        minLines: 2,
        maxLines: 6,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: label, hintText: hint, alignLabelWithHint: true),
        onChanged: (_) => setState(() {}),
      );

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesScope(
      dirty: _dirty,
      busy: _submitting,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
        children: [
          // Kapsam da ticari şartlardandır (aktivasyonla birlikte kilitlenir);
          // tek alanlı ayrı bir "Kapsam" bölümü başlığı alan etiketini tekrar
          // ederdi.
          AppFormSection(
            title: 'Kapsam ve Ticari Koşullar',
            subtitle: 'Aktivasyonla birlikte kilitlenir.',
            children: [
              _multiline(_scope, 'Kapsam', hint: 'Sözleşme kapsamı'),
              _multiline(_payment, 'Ödeme Koşulları'),
              _multiline(_retention, 'Hakediş Koşulları'),
              _multiline(_advance, 'Avans Koşulları'),
            ],
          ),
          AppFormSection(
            title: 'Tarihler',
            children: [
              ContractCoDateField(
                label: 'Yürürlük Tarihi',
                value: _effectiveDate,
                onChanged: (v) => setState(() => _effectiveDate = v),
              ),
              ContractCoDateField(
                label: 'Planlanan Bitiş Tarihi',
                value: _plannedCompletionDate,
                onChanged: (v) => setState(() => _plannedCompletionDate = v),
              ),
              if (_dateOrderError != null)
                Text(_dateOrderError!, key: const ValueKey('contract-date-order-error'), style: AppTypography.error),
            ],
          ),
          if (_error != null) ...[
            Text(_error!, style: AppTypography.error),
            const SizedBox(height: AppSpacing.md),
          ],
          PrimaryButton(label: 'Kaydet', loading: _submitting, onPressed: _submit),
        ],
      ),
    );
  }
}
