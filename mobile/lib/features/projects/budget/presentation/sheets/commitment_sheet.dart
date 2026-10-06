import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_spacing.dart';
import '../../../../../core/theme/app_typography.dart';
import '../../../../../core/utils/formatters.dart';
import '../../../../../core/widgets/app_data_row.dart';
import '../../../../../core/widgets/status_badge.dart';
import '../../../../../core/widgets/unsaved_changes_scope.dart';
import '../../../presentation/destructive_action_button.dart';
import '../../data/budget_providers.dart';
import '../../domain/budget.dart';
import '../widgets/budget_ui.dart';
import '../../../../../core/widgets/app_sheet.dart';

/// Taahhüt detayı + (izin, durum ve kaynak uygunsa) iptal. İptal edilirse
/// true döner.
Future<bool?> showCommitmentSheet(
  BuildContext context, {
  required String projectId,
  required Commitment commitment,
  required bool canVoid,
  String? budgetLineLabel,
}) {
  return showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => CommitmentSheet(
      projectId: projectId,
      commitment: commitment,
      canVoid: canVoid,
      budgetLineLabel: budgetLineLabel,
    ),
  );
}

class CommitmentSheet extends ConsumerStatefulWidget {
  const CommitmentSheet({
    super.key,
    required this.projectId,
    required this.commitment,
    required this.canVoid,
    this.budgetLineLabel,
  });

  final String projectId;
  final Commitment commitment;

  /// İzin (cost_control.manage) + açık proje -- ÇAĞIRAN belirler. Kaynak/durum
  /// kuralı ([canVoidCommitmentHere]) burada ayrıca uygulanır.
  final bool canVoid;
  final String? budgetLineLabel;

  @override
  ConsumerState<CommitmentSheet> createState() => _CommitmentSheetState();
}

class _CommitmentSheetState extends ConsumerState<CommitmentSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _void() async {
    final c = widget.commitment;
    final reason = await promptBudgetReason(
      context,
      title: 'Taahhüdü İptal Et',
      message:
          '"${c.description}" (${Formatters.money(c.committedAmount, currency: c.currency)}) taahhüdü iptal '
          'edilecek — bu tutar artık taahhüt toplamına dahil edilmeyecek.',
      confirmLabel: 'İptal Et',
    );
    if (reason == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await container.read(budgetRepositoryProvider).voidCommitment(widget.projectId, c.id, reason: reason);
      invalidateBudgetModule(container.invalidate, widget.projectId);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      // 409: zaten iptal edilmiş -- liste tazelenir, mesaj gösterilir.
      if (isBudgetConflict(e)) invalidateBudgetModule(container.invalidate, widget.projectId);
      if (mounted) setState(() => _error = budgetErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.commitment;
    final voided = c.isVoided || c.status == 'voided';
    final showVoid = widget.canVoid && canVoidCommitmentHere(c);
    final sourceNote = switch (c.sourceType) {
      'purchase_order' =>
        'Bu taahhüt bir satın alma siparişinin onayıyla oluştu; siparişin kendi yaşam döngüsüyle (iptal) yönetilir.',
      'subcontract' =>
        'Bu taahhüt bir taşeron sözleşmesinden oluştu; sözleşmenin kendi yaşam döngüsüyle (değişiklik/fesih) yönetilir.',
      _ => null,
    };

    return UnsavedChangesScope(
      busy: _busy,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              c.description.isEmpty ? 'Taahhüt' : c.description,
              style: AppTypography.pageTitle.copyWith(fontSize: 17),
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                StatusBadge(label: commitmentSourceLabel(c.sourceType), tone: StatusTone.muted),
                StatusRegistry.build(c.status, BudgetStatusRegistry.commitment),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AppDataRow(
              label: 'Tutar',
              value: Formatters.money(c.committedAmount, currency: c.currency),
              emphasize: true,
              valueColor: voided ? AppColors.textMuted : null,
            ),
            AppDataRow(label: 'Tarih', value: Formatters.date(c.committedAt)),
            AppDataRow(label: 'Maliyet Kodu', value: '${c.costCodeCode} — ${c.costCodeName}', multiline: true),
            AppDataRow(
              label: 'Bütçe Kalemi',
              value: c.budgetLineId == null ? 'Bağlı değil (bütçe dışı)' : (widget.budgetLineLabel ?? '—'),
              multiline: true,
            ),
            if (voided) ...[
              if (c.voidedAt != null) AppDataRow(label: 'İptal Tarihi', value: Formatters.date(c.voidedAt)),
              if (c.voidReason.isNotEmpty) AppDataRow(label: 'İptal Nedeni', value: c.voidReason, multiline: true),
            ],
            if (sourceNote != null) ...[const SizedBox(height: AppSpacing.md), BudgetInfoNote(sourceNote)],
            if (_error != null) ...[const SizedBox(height: AppSpacing.md), Text(_error!, style: AppTypography.error)],
            if (showVoid) ...[
              const SizedBox(height: AppSpacing.lg),
              DestructiveActionButton(
                key: const ValueKey('commitment-void'),
                label: 'Taahhüdü İptal Et',
                icon: Icons.block,
                loading: _busy,
                onPressed: _busy ? null : _void,
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: const Text('Kapat')),
          ],
        ),
      ),
    );
  }
}
