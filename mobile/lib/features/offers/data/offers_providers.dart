import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/offer.dart';
import 'offers_repository.dart';

final offersRepositoryProvider =
    Provider<OffersRepository>((ref) => OffersRepository(ref.watch(apiClientProvider)));

final offersListProvider = FutureProvider.autoDispose.family<({List<Offer> offers, int total}), String>(
  (ref, filter) => ref.watch(offersRepositoryProvider).list(filter: filter),
);

final offerDetailProvider = FutureProvider.autoDispose.family<Offer, String>(
  (ref, id) => ref.watch(offersRepositoryProvider).get(id),
);

final offerRevisionsProvider = FutureProvider.autoDispose.family<List<OfferRevision>, String>(
  (ref, id) => ref.watch(offersRepositoryProvider).revisions(id),
);

final offerHasProjectProvider = FutureProvider.autoDispose.family<bool, String>(
  (ref, id) => ref.watch(offersRepositoryProvider).hasProject(id),
);
