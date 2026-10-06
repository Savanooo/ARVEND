import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/errors/api_exception.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/app_data_row.dart';
import '../../../../core/widgets/unsaved_changes_scope.dart';
import '../../contract_co/presentation/widgets/contract_co_ui.dart' show showReasonDialog;
import '../../data/projects_providers.dart';
import '../../presentation/destructive_action_button.dart';
import '../../domain/project.dart';
import '../data/finance_ledger_providers.dart';
import '../../../../core/widgets/app_sheet.dart';

/// Masraf / tahsilat satırına dokununca açılan ayrıntı sayfası (web
/// tablosundaki tüm sütunlar + bağlar + iptal gerekçesi) ve "İptal Et"
/// (web: `POST .../{id}/void {reason}`). İptal yalnızca `projects.finance.
/// manage` + açık proje + henüz iptal edilmemiş kayıtta görünür ([canVoid]);
/// kayıt SİLİNMEZ, üstü çizili kalır ve toplamlardan düşer. Gerekçe
/// uygulamada zorunludur (satın alma/taahhüt iptalleriyle aynı desen).
/// İptal edildiyse `true` döner.
Future<bool?> showExpenseDetailSheet(
  BuildContext context, {
  required String projectId,
  required Expense expense,
  required String currency,
  required bool canVoid,
  String? changeOrderLabel,
  String? costCodeLabel,
}) {
  final rows = <Widget>[
    AppDataRow(label: 'Tarih', value: Formatters.date(expense.expenseDate)),
    AppDataRow(label: 'Kategori', value: expenseCategories[expense.category] ?? expense.category),
    AppDataRow(label: 'Açıklama', value: expense.description.isEmpty ? '—' : expense.description, multiline: true),
    AppDataRow(label: 'Tedarikçi', value: expense.supplierName.isEmpty ? '—' : expense.supplierName),
    AppDataRow(label: 'Fatura No', value: expense.invoiceNo.isEmpty ? '—' : expense.invoiceNo),
    if (changeOrderLabel != null) AppDataRow(label: 'Ek İş', value: changeOrderLabel, multiline: true),
    if (costCodeLabel != null) AppDataRow(label: 'Maliyet Kodu', value: costCodeLabel, multiline: true),
    if (expense.notes.isNotEmpty) AppDataRow(label: 'Not', value: expense.notes, multiline: true),
  ];
  return _showLedgerSheet(
    context,
    projectId: projectId,
    title: 'Masraf',
    amount: Formatters.money(expense.amount, currency: expense.currency.isEmpty ? currency : expense.currency),
    voided: expense.isVoided,
    voidReason: expense.voidReason,
    rows: rows,
    canVoid: canVoid,
    voidTitle: 'Masrafı İptal Et',
    voidMessage: 'Masraf iptal edilir, gerçekleşen maliyetten düşer. Kayıt silinmez; listede üstü çizili kalır.',
    doneMessage: 'Masraf iptal edildi.',
    onVoid: (container, reason) async {
      await container.read(projectsRepositoryProvider).voidExpense(projectId, expense.id, reason: reason);
      invalidateProjectLedger(container.invalidate, projectId);
    },
  );
}

Future<bool?> showCollectionDetailSheet(
  BuildContext context, {
  required String projectId,
  required Collection collection,
  required String currency,
  required bool canVoid,
  String? planItemLabel,
}) {
  final rows = <Widget>[
    AppDataRow(label: 'Tarih', value: Formatters.date(collection.receivedDate)),
    AppDataRow(label: 'Ödeme Yöntemi', value: collection.paymentMethod.isEmpty ? '—' : collection.paymentMethod),
    AppDataRow(
      label: 'Açıklama',
      value: collection.description.isEmpty ? '—' : collection.description,
      multiline: true,
    ),
    AppDataRow(label: 'Referans No', value: collection.referenceNo.isEmpty ? '—' : collection.referenceNo),
    if (planItemLabel != null) AppDataRow(label: 'Ödeme Planı Kalemi', value: planItemLabel, multiline: true),
  ];
  return _showLedgerSheet(
    context,
    projectId: projectId,
    title: 'Tahsilat',
    amount: Formatters.money(collection.amount, currency: collection.currency.isEmpty ? currency : collection.currency),
    voided: collection.isVoided,
    voidReason: collection.voidReason,
    rows: rows,
    canVoid: canVoid,
    voidTitle: 'Tahsilatı İptal Et',
    voidMessage: 'Tahsilat iptal edilir; tahsil edilen tutardan ve bağlı ödeme planı kaleminden düşer. Kayıt silinmez.',
    doneMessage: 'Tahsilat iptal edildi.',
    onVoid: (container, reason) async {
      await container.read(projectsRepositoryProvider).voidCollection(projectId, collection.id, reason: reason);
      invalidateProjectLedger(container.invalidate, projectId);
    },
  );
}

Future<bool?> _showLedgerSheet(
  BuildContext context, {
  required String projectId,
  required String title,
  required String amount,
  required bool voided,
  required String voidReason,
  required List<Widget> rows,
  required bool canVoid,
  required String voidTitle,
  required String voidMessage,
  required String doneMessage,
  required Future<void> Function(ProviderContainer container, String reason) onVoid,
}) {
  return showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _LedgerSheet(
      projectId: projectId,
      title: title,
      amount: amount,
      voided: voided,
      voidReason: voidReason,
      rows: rows,
      canVoid: canVoid && !voided,
      voidTitle: voidTitle,
      voidMessage: voidMessage,
      doneMessage: doneMessage,
      onVoid: onVoid,
    ),
  );
}

class _LedgerSheet extends ConsumerStatefulWidget {
  const _LedgerSheet({
    required this.projectId,
    required this.title,
    required this.amount,
    required this.voided,
    required this.voidReason,
    required this.rows,
    required this.canVoid,
    required this.voidTitle,
    required this.voidMessage,
    required this.doneMessage,
    required this.onVoid,
  });

  final String projectId;
  final String title;
  final String amount;
  final bool voided;
  final String voidReason;
  final List<Widget> rows;
  final bool canVoid;
  final String voidTitle;
  final String voidMessage;
  final String doneMessage;

  /// Kapsayıcıyla çalışır (sayfanın `ref`'iyle DEĞİL): istek sürerken sayfa
  /// kapanırsa `WidgetRef` StateError atar ve tazeleme kaybolurdu.
  final Future<void> Function(ProviderContainer container, String reason) onVoid;

  @override
  ConsumerState<_LedgerSheet> createState() => _LedgerSheetState();
}

class _LedgerSheetState extends ConsumerState<_LedgerSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _void() async {
    final reason = await showReasonDialog(
      context,
      title: widget.voidTitle,
      message: widget.voidMessage,
      confirmLabel: 'İptal Et',
      reasonLabel: 'İptal nedeni',
    );
    if (reason == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await widget.onVoid(container, reason);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop(true);
      messenger?.showSnackBar(SnackBar(content: Text(widget.doneMessage)));
    } on ApiException catch (e) {
      // 409 (proje bu arada kapandı / kayıt zaten iptal) ya da 403: sunucu
      // mesajı gösterilir, listeler tazelenir.
      if (e.kind == ApiErrorKind.conflict || e.kind == ApiErrorKind.notFound) {
        final projectId = widget.projectId;
        invalidateProjectLedger(container.invalidate, projectId);
        container.invalidate(projectDetailProvider(projectId));
      }
      if (!mounted) return;
      setState(() => _error = e.isForbidden ? 'Bu işlem için yetkin yok.' : e.message);
    } catch (_) {
      // Beklenmeyen hata (ör. ağ katmanı dışı): sayfada kalır, çökme yok.
      if (mounted) setState(() => _error = 'İşlem tamamlanamadı. Lütfen tekrar dene.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesScope(
      busy: _busy,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.xl,
          AppSpacing.lg,
          AppSpacing.xl,
          MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(child: Text(widget.title, style: AppTypography.sectionTitle)),
                  Text(
                    widget.amount,
                    style: AppTypography.cardTitle.copyWith(
                      decoration: widget.voided ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ],
              ),
              if (widget.voided) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  widget.voidReason.isEmpty ? 'İPTAL' : 'İPTAL · ${widget.voidReason}',
                  style: AppTypography.metadata.copyWith(color: AppColors.danger, fontWeight: FontWeight.w600),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              ...widget.rows,
              if (_error != null) ...[const SizedBox(height: AppSpacing.md), Text(_error!, style: AppTypography.error)],
              if (widget.canVoid) ...[
                const SizedBox(height: AppSpacing.lg),
                DestructiveActionButton(
                  label: 'İptal Et',
                  icon: Icons.block_outlined,
                  loading: _busy,
                  onPressed: _busy ? null : _void,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
