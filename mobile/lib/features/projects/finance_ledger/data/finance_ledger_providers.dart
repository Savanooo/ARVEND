import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_providers.dart';
import '../../activity/data/project_activity_providers.dart';
import '../../budget/data/budget_providers.dart';
import '../../data/projects_providers.dart';
import '../../finance_plan/data/finance_plan_providers.dart';
import '../../my_expenses/data/my_expenses_repository.dart';
import '../domain/legacy_subcontractor.dart';
import 'finance_ledger_repository.dart';

/// Proje finans izinleri (backend domain.PermProjectsFinance*). Tahsilat,
/// masraf ve legacy taşeron ödemeleri aynı çifti kullanır.
const kLedgerReadPermission = 'projects.finance.read';
const kLedgerManagePermission = 'projects.finance.manage';

final financeLedgerRepositoryProvider =
    Provider<FinanceLedgerRepository>((ref) => FinanceLedgerRepository(ref.watch(apiClientProvider)));

final legacySubcontractorsProvider = FutureProvider.autoDispose.family<List<LegacySubcontractor>, String>(
  (ref, projectId) => ref.watch(financeLedgerRepositoryProvider).subcontractors(projectId),
);

final legacySubcontractorPaymentsProvider =
    FutureProvider.autoDispose.family<List<LegacySubcontractorPayment>, String>(
  (ref, projectId) => ref.watch(financeLedgerRepositoryProvider).subcontractorPayments(projectId),
);

/// Tahsilat/masraf/taşeron ödemesi yazıldıktan (ya da iptal edildikten) sonra
/// etkilenen TÜM okumalar: listeler, finans özeti (gerçekleşen maliyet,
/// tahsil edilen), ödeme planı (kalemin "Tahsil Edilen"i tahsilat bağından
/// hesaplanır), maliyet kontrolü (masraflar gerçekleşen maliyete girer) ve
/// proje hareketleri, kişinin "Masraflarım" listesi. autoDispose oldukları
/// için yalnızca izlenenler yeniden istek atar.
void invalidateProjectLedger(void Function(ProviderOrFamily provider) invalidate, String projectId) {
  invalidate(projectExpensesProvider(projectId));
  invalidate(myExpensesProvider);
  invalidate(projectCollectionsProvider(projectId));
  invalidate(projectFinancialSummaryProvider(projectId));
  invalidate(projectPaymentPlanProvider(projectId));
  invalidate(legacySubcontractorsProvider(projectId));
  invalidate(legacySubcontractorPaymentsProvider(projectId));
  invalidate(projectActivityProvider(projectId));
  invalidate(budgetActualExpensesProvider(projectId));
  invalidateBudgetModule(invalidate, projectId);
}
