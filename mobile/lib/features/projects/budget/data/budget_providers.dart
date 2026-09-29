import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_providers.dart';
import '../../data/projects_providers.dart' show projectCostControlProvider, projectDetailProvider;
import '../../domain/project.dart' show Project;
import '../domain/budget.dart';
import 'budget_repository.dart';

final budgetRepositoryProvider = Provider<BudgetRepository>((ref) => BudgetRepository(ref.watch(apiClientProvider)));

/// Alt ekranların kilit (tamamlanan/iptal proje) ve para birimi bilgisi --
/// proje detayı yığında açıkken önbellekteki kaydı paylaşır.
final budgetProjectProvider = FutureProvider.autoDispose.family<Project, String>(
  (ref, projectId) => ref.watch(projectDetailProvider(projectId).future),
);

final budgetCostControlProvider = FutureProvider.autoDispose.family<CostControlData, String>(
  (ref, projectId) => ref.watch(budgetRepositoryProvider).costControl(projectId),
);

final projectBudgetProvider = FutureProvider.autoDispose.family<ProjectBudget?, String>(
  (ref, projectId) => ref.watch(budgetRepositoryProvider).budget(projectId),
);

final budgetLinesProvider = FutureProvider.autoDispose.family<List<BudgetLine>, String>(
  (ref, projectId) => ref.watch(budgetRepositoryProvider).budgetLines(projectId),
);

final budgetWbsNodesProvider = FutureProvider.autoDispose.family<List<WbsNode>, String>(
  (ref, projectId) => ref.watch(budgetRepositoryProvider).wbsNodes(projectId),
);

final budgetAdjustmentsProvider = FutureProvider.autoDispose.family<List<BudgetAdjustment>, String>(
  (ref, projectId) => ref.watch(budgetRepositoryProvider).adjustments(projectId),
);

final budgetCommitmentsProvider = FutureProvider.autoDispose.family<List<Commitment>, String>(
  (ref, projectId) => ref.watch(budgetRepositoryProvider).commitments(projectId),
);

final budgetForecastsProvider = FutureProvider.autoDispose.family<List<CostForecast>, String>(
  (ref, projectId) => ref.watch(budgetRepositoryProvider).forecasts(projectId),
);

final budgetActualExpensesProvider = FutureProvider.autoDispose.family<List<ActualExpense>, String>(
  (ref, projectId) => ref.watch(budgetRepositoryProvider).expenses(projectId),
);

/// Organizasyon kataloğu (proje-bağımsız) -- kalem/taahhüt formu seçicisi.
final budgetCostCodesProvider = FutureProvider.autoDispose<List<OrgCostCode>>(
  (ref) => ref.watch(budgetRepositoryProvider).costCodes(),
);

/// "Bugün" -- taahhüt formunun varsayılan tarihi; testlerde sabitlenir.
final budgetClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Herhangi bir bütçe/maliyet yazmasından sonra: bu modülün TÜM proje
/// sağlayıcıları + proje detayının Finans özet kartının kullandığı
/// `projectCostControlProvider` (EAC/tahmini kâr orada da görünür) tazelenir.
/// autoDispose oldukları için yalnızca o an izlenenler yeniden istek atar.
/// `ref.invalidate` ya da `ProviderContainer.invalidate` verilir.
void invalidateBudgetModule(void Function(ProviderOrFamily provider) invalidate, String projectId) {
  invalidate(budgetCostControlProvider(projectId));
  invalidate(projectBudgetProvider(projectId));
  invalidate(budgetLinesProvider(projectId));
  invalidate(budgetWbsNodesProvider(projectId));
  invalidate(budgetAdjustmentsProvider(projectId));
  invalidate(budgetCommitmentsProvider(projectId));
  invalidate(budgetForecastsProvider(projectId));
  invalidate(projectCostControlProvider(projectId));
}
