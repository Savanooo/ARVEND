import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/customer.dart';
import 'customers_repository.dart';

final customersRepositoryProvider =
    Provider<CustomersRepository>((ref) => CustomersRepository(ref.watch(apiClientProvider)));

final customersListProvider = FutureProvider.autoDispose.family<List<Customer>, String>(
  (ref, q) => ref.watch(customersRepositoryProvider).list(q: q),
);

final customerDetailProvider = FutureProvider.autoDispose.family<Customer, String>(
  (ref, id) => ref.watch(customersRepositoryProvider).get(id),
);
