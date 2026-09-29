import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_providers.dart';
import '../../data/projects_providers.dart';
import '../domain/project_change_order.dart';
import '../domain/project_contract.dart';
import 'contract_co_repository.dart';

final contractCoRepositoryProvider =
    Provider<ContractCoRepository>((ref) => ContractCoRepository(ref.watch(apiClientProvider)));

/// `null` = bu projenin henüz sözleşmesi yok (404) -- hata DEĞİL.
final projectContractProvider = FutureProvider.autoDispose.family<ProjectContract?, String>(
  (ref, projectId) => ref.watch(contractCoRepositoryProvider).contract(projectId),
);

/// Tam DTO'lu ek iş listesi (kârlılık + aktif link dahil). `projects_
/// providers.dart`'taki dar `projectChangeOrdersProvider` (eski salt-okunur
/// sekme) ayrı bir sağlayıcıdır; yazma sonrası ikisi de tazelenir
/// ([invalidateChangeOrders]).
final projectChangeOrderListProvider = FutureProvider.autoDispose.family<List<ProjectChangeOrder>, String>(
  (ref, projectId) => ref.watch(contractCoRepositoryProvider).changeOrders(projectId),
);

typedef ChangeOrderKey = ({String projectId, String changeOrderId});

final projectChangeOrderDetailProvider = FutureProvider.autoDispose.family<ProjectChangeOrder, ChangeOrderKey>(
  (ref, key) => ref.watch(contractCoRepositoryProvider).changeOrder(key.projectId, key.changeOrderId),
);

final contractValueSummaryProvider = FutureProvider.autoDispose.family<ContractValueSummary, String>(
  (ref, projectId) => ref.watch(contractCoRepositoryProvider).contractValueSummary(projectId),
);

final changeOrderEventsProvider = FutureProvider.autoDispose.family<List<ChangeOrderEvent>, String>(
  (ref, projectId) => ref.watch(contractCoRepositoryProvider).changeOrderEvents(projectId),
);

/// Bir ek iş yazıldıktan sonra etkilenen TÜM okumalar: liste, (varsa)
/// detay, değer özeti, olaylar ve proje ekranının kendi finans okumaları
/// (onay bekleyen tutar, eski dar liste). Sözleşme ekranındaki "Bu
/// Sözleşmeyi Değiştiren Ek İşler" aynı listeyi izler.
///
/// [invalidate]: bir `await`'ten SONRA çağrılacaksa, ekran bu arada
/// kapanmış olabilir -- `WidgetRef.invalidate` o durumda StateError atar ve
/// tazeleme sessizce kaybolur. Çağıran bu yüzden kapsayıcının
/// (`ProviderScope.containerOf(context, listen: false).invalidate`) ilk
/// `await`'ten ÖNCE alınmış halini verir; eşzamanlı yerlerde `ref.invalidate`
/// de olur.
void invalidateChangeOrders(
  void Function(ProviderOrFamily provider) invalidate,
  String projectId, {
  String? changeOrderId,
}) {
  invalidate(projectChangeOrderListProvider(projectId));
  if (changeOrderId != null) {
    invalidate(projectChangeOrderDetailProvider((projectId: projectId, changeOrderId: changeOrderId)));
  }
  invalidate(contractValueSummaryProvider(projectId));
  invalidate(changeOrderEventsProvider(projectId));
  invalidate(projectChangeOrdersProvider(projectId));
  invalidate(projectFinancialSummaryProvider(projectId));
}
