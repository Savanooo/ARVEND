import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_status_colors.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../budget/domain/budget.dart' show kCostCodesReadPermission;
import '../../data/projects_providers.dart';
import '../../domain/project.dart';
import '../../domain/subcontract.dart' show OrgCostCode;
import '../../finance_plan/data/finance_plan_providers.dart';
import '../../presentation/collection_form_sheet.dart';
import '../../presentation/expense_form_sheet.dart';
import '../data/finance_ledger_providers.dart';
import 'ledger_entry_sheet.dart';
import 'ledger_ui.dart';
import '../../presentation/form_project_banner.dart';

/// "Masraf Ekle" formunu açar; kayıt oluşursa etkilenen TÜM okumaları
/// (liste, finans özeti, maliyet kontrolü, ödeme planı, aktivite) tazeler.
/// Proje detayının Finans görünümü ve Özet'in hızlı işlemi aynı yolu kullanır.
/// Kapsayıcı sayfa açılmadan ÖNCE alınır: form kapanana kadar çağıran
/// widget ağaçtan kalksa da tazeleme yapılır.
Future<bool> addProjectExpense(BuildContext context, Project project) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final created = await showExpenseFormSheet(
    context,
    project.id,
    currency: project.currency,
    projectLabel: formProjectLabel(project.projectNo, project.name),
  );
  if (created == null) return false;
  invalidateProjectLedger(container.invalidate, project.id);
  return true;
}

/// "Tahsilat Ekle" -- [addProjectExpense] ile aynı tazeleme (ödeme planı
/// kaleminin "Tahsil Edilen"i bağlı tahsilattan hesaplanır).
/// [initialPlanItemId]: ödeme planı kalemi detayından açılınca tahsilat o
/// kaleme bağlı başlar.
Future<bool> addProjectCollection(BuildContext context, Project project, {String? initialPlanItemId}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final created = await showCollectionFormSheet(
    context,
    project.id,
    currency: project.currency,
    initialPlanItemId: initialPlanItemId,
    projectLabel: formProjectLabel(project.projectNo, project.name),
  );
  if (created == null) return false;
  invalidateProjectLedger(container.invalidate, project.id);
  return true;
}

/// Finans görünümündeki kilit notu: tamamlanmış/iptal edilmiş projede yeni
/// hareket girilemez ve iptal edilemez (web `LockedNote`). Yalnızca yazma
/// izni olan kişiye gösterilir -- salt-okur için zaten düğme yoktur.
class LedgerLockedNotice extends ConsumerWidget {
  const LedgerLockedNotice({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    if (!isLedgerLocked(project.status) || !user.can(kLedgerManagePermission)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: ReadOnlyNotice(ledgerLockedText(project.status)),
    );
  }
}

/// Finans > Masraflar (web `ExpensesSection` tablosu): tarih · kategori ·
/// açıklama · bağlı ek iş / maliyet kodu · tedarikçi · tutar; iptal
/// edilenler soluk + üstü çizili + "İPTAL · gerekçe". Satıra dokununca
/// ayrıntı + "İptal Et". Altında geçerli masraf toplamı ve çift sayım notu.
/// Görünüm `projects.finance.read` ile açılır (proje detayı gizler);
/// "Masraf Ekle" / "İptal Et" `projects.finance.manage` + açık proje.
class ExpensesLedgerSection extends ConsumerWidget {
  const ExpensesLedgerSection({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectId = project.id;
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user.can(kLedgerManagePermission) && !isLedgerLocked(project.status);
    final expensesAsync = ref.watch(projectExpensesProvider(projectId));
    final expenses = expensesAsync.valueOrNull ?? const <Expense>[];

    // Bağ etiketleri yalnızca bağlı bir kayıt varsa istenir (gereksiz istek
    // yok); maliyet kodları ayrıca kataloğu okuma iznini ister.
    final changeOrders = expenses.any((e) => e.changeOrderId != null)
        ? ref.watch(projectChangeOrdersProvider(projectId)).valueOrNull ?? const <ChangeOrder>[]
        : const <ChangeOrder>[];
    final costCodes = expenses.any((e) => e.costCodeId != null) && user.can(kCostCodesReadPermission)
        ? ref.watch(orgCostCodesProvider).valueOrNull ?? const <OrgCostCode>[]
        : const <OrgCostCode>[];
    ChangeOrder? changeOrderOf(String id) {
      for (final co in changeOrders) {
        if (co.id == id) return co;
      }
      return null;
    }

    // Satırda web'deki gibi yalnızca ek iş numarası, ayrıntıda numara + başlık.
    String? changeOrderNo(String? id) => id == null ? null : (changeOrderOf(id)?.changeOrderNo ?? 'Ek iş');
    String? changeOrderLabel(String? id) {
      if (id == null) return null;
      final co = changeOrderOf(id);
      return co == null ? 'Ek iş' : '${co.changeOrderNo} · ${co.title}';
    }

    String? costCodeLabel(String? id) {
      if (id == null) return null;
      for (final c in costCodes) {
        if (c.id == id) return '${c.code} — ${c.name}';
      }
      return 'Maliyet kodu';
    }

    final validTotal = expenses.where((e) => !e.isVoided).fold<double>(0, (sum, e) => sum + e.amount);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSectionHeader(
          title: 'Masraflar',
          trailing: canManage
              ? TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Masraf Ekle'),
                  onPressed: () => addProjectExpense(context, project),
                )
              : null,
        ),
        AsyncStateView(
          value: expensesAsync,
          onRetry: () async => ref.invalidate(projectExpensesProvider(projectId)),
          isEmpty: (list) => list.isEmpty,
          emptyBuilder: (_) => const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: EmptyStateView(message: 'Henüz masraf kaydı yok.'),
          ),
          data: (context, list) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final e in list)
                _LedgerRow(
                  key: ValueKey('masraf-${e.id}'),
                  title: expenseCategories[e.category] ?? e.category,
                  parts: [
                    Formatters.date(e.expenseDate),
                    if (e.description.isNotEmpty) e.description,
                    if (e.supplierName.isNotEmpty) e.supplierName,
                    if (e.changeOrderId != null) changeOrderNo(e.changeOrderId)!,
                  ],
                  amount: Formatters.money(e.amount, currency: e.currency.isEmpty ? project.currency : e.currency),
                  voided: e.isVoided,
                  voidReason: e.voidReason,
                  onTap: () => showExpenseDetailSheet(
                    context,
                    projectId: projectId,
                    expense: e,
                    currency: project.currency,
                    canVoid: canManage,
                    changeOrderLabel: changeOrderLabel(e.changeOrderId),
                    costCodeLabel: costCodeLabel(e.costCodeId),
                  ),
                ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  const Expanded(child: Text('Geçerli masraf toplamı', style: AppTypography.metadata)),
                  Text(
                    Formatters.money(validTotal, currency: project.currency),
                    style: AppTypography.body.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        const Text(
          'Taşeron ödemeleri buraya girilmez — çift sayımı önlemek için yalnızca Taşeron Ödemeleri bölümünden '
          'kaydedilir.',
          style: AppTypography.helper,
        ),
      ],
    );
  }
}

/// Finans > Tahsilatlar (web `CollectionsSection`): tarih · açıklama ·
/// yöntem · bağlı ödeme planı kalemi · tutar; iptal akışı masraflarla aynı.
class CollectionsLedgerSection extends ConsumerWidget {
  const CollectionsLedgerSection({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectId = project.id;
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canManage = user.can(kLedgerManagePermission) && !isLedgerLocked(project.status);
    final collectionsAsync = ref.watch(projectCollectionsProvider(projectId));
    final collections = collectionsAsync.valueOrNull ?? const <Collection>[];
    final planItems = collections.any((c) => c.paymentPlanItemId != null)
        ? ref.watch(projectPaymentPlanProvider(projectId)).valueOrNull?.items ?? const []
        : const [];
    String? planItemLabel(String? id) {
      if (id == null) return null;
      for (final item in planItems) {
        if (item.id == id) return item.name;
      }
      return 'Ödeme planı kalemi';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSectionHeader(
          title: 'Tahsilatlar',
          trailing: canManage
              ? TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Tahsilat Ekle'),
                  onPressed: () => addProjectCollection(context, project),
                )
              : null,
        ),
        AsyncStateView(
          value: collectionsAsync,
          onRetry: () async => ref.invalidate(projectCollectionsProvider(projectId)),
          isEmpty: (list) => list.isEmpty,
          emptyBuilder: (_) => const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: EmptyStateView(message: 'Henüz tahsilat kaydı yok.'),
          ),
          data: (context, list) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final c in list)
                _LedgerRow(
                  key: ValueKey('tahsilat-${c.id}'),
                  title: c.paymentMethod.isEmpty ? 'Tahsilat' : c.paymentMethod,
                  parts: [
                    Formatters.date(c.receivedDate),
                    if (c.description.isNotEmpty) c.description,
                    if (c.referenceNo.isNotEmpty) c.referenceNo,
                    if (c.paymentPlanItemId != null) planItemLabel(c.paymentPlanItemId)!,
                  ],
                  amount: Formatters.money(c.amount, currency: c.currency.isEmpty ? project.currency : c.currency),
                  amountColor: AppStatusColors.success,
                  voided: c.isVoided,
                  voidReason: c.voidReason,
                  onTap: () => showCollectionDetailSheet(
                    context,
                    projectId: projectId,
                    collection: c,
                    currency: project.currency,
                    canVoid: canManage,
                    planItemLabel: planItemLabel(c.paymentPlanItemId),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Tek defter satırı (kart): başlık + tek satır ayrıntı, sağda tutar; iptal
/// edilen kayıt soluk, tutarı üstü çizili, altında kırmızı "İPTAL · gerekçe".
class _LedgerRow extends StatelessWidget {
  const _LedgerRow({
    super.key,
    required this.title,
    required this.parts,
    required this.amount,
    required this.voided,
    required this.voidReason,
    required this.onTap,
    this.amountColor,
  });

  final String title;
  final List<String> parts;
  final String amount;
  final Color? amountColor;
  final bool voided;
  final String voidReason;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: voided ? 0.6 : 1,
      child: Card(
        margin: const EdgeInsets.only(top: AppSpacing.sm),
        child: ListTile(
          onTap: onTap,
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(parts.join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
              if (voided)
                Text(
                  voidReason.isEmpty ? 'İPTAL' : 'İPTAL · $voidReason',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.metadata.copyWith(color: AppColors.danger, fontWeight: FontWeight.w600),
                ),
            ],
          ),
          trailing: Text(
            amount,
            style: TextStyle(
              decoration: voided ? TextDecoration.lineThrough : null,
              fontWeight: FontWeight.w600,
              color: voided ? AppColors.textMuted : amountColor,
            ),
          ),
        ),
      ),
    );
  }
}
