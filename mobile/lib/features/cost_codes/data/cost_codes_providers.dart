import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/cost_code.dart';
import 'cost_codes_repository.dart';

final costCodesRepositoryProvider =
    Provider<CostCodesRepository>((ref) => CostCodesRepository(ref.watch(apiClientProvider)));

/// Tüm katalog tek istekte gelir (backend sayfalama yapmaz); arama, aktif/
/// arşiv süzmesi ve kategori gruplaması ekranda yapılır -- web ile aynı.
/// `projects_providers.dart`'taki `orgCostCodesProvider` (SOV kalemi
/// seçicisi) ayrı bir sağlayıcıdır.
final costCodesListProvider = FutureProvider.autoDispose<List<OrganizationCostCode>>(
  (ref) => ref.watch(costCodesRepositoryProvider).list(),
);

final costCodeDetailProvider = FutureProvider.autoDispose.family<OrganizationCostCode, String>(
  (ref, id) => ref.watch(costCodesRepositoryProvider).get(id),
);
