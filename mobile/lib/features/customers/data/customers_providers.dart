import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/customer.dart';
import 'customers_repository.dart';

final customersRepositoryProvider =
    Provider<CustomersRepository>((ref) => CustomersRepository(ref.watch(apiClientProvider)));

typedef CustomerListQuery = ({String q, String filter});

final customersListProvider = FutureProvider.autoDispose.family<List<Customer>, CustomerListQuery>(
  (ref, query) => ref.watch(customersRepositoryProvider).list(q: query.q, filter: query.filter),
);

final customerDetailProvider = FutureProvider.autoDispose.family<Customer, String>(
  (ref, id) => ref.watch(customersRepositoryProvider).get(id),
);
