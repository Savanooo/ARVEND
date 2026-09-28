import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/supplier.dart';
import 'suppliers_repository.dart';

final suppliersRepositoryProvider =
    Provider<SuppliersRepository>((ref) => SuppliersRepository(ref.watch(apiClientProvider)));

/// Tüm katalog tek istekte gelir (backend sayfalama yapmaz); arama ve
/// aktif/arşiv süzmesi ekranda `filterSuppliers` ile yapılır -- web ile aynı.
/// `projects_providers.dart`'taki `suppliersProvider` (taşeron formunun
/// seçici listesi) ayrı bir sağlayıcıdır.
final suppliersListProvider = FutureProvider.autoDispose<List<OrganizationSupplier>>(
  (ref) => ref.watch(suppliersRepositoryProvider).list(),
);

final supplierDetailProvider = FutureProvider.autoDispose.family<OrganizationSupplier, String>(
  (ref, id) => ref.watch(suppliersRepositoryProvider).get(id),
);
