import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/calc.dart';
import 'calc_repository.dart';

final calcRepositoryProvider = Provider<CalcRepository>((ref) => CalcRepository(ref.watch(apiClientProvider)));

final calcCatalogProvider = FutureProvider.autoDispose<List<CalcGroupWithCategories>>(
  (ref) => ref.watch(calcRepositoryProvider).groupsWithCategories(),
);
