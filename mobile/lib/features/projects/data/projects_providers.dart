import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/project.dart';
import 'projects_repository.dart';

final projectsRepositoryProvider =
    Provider<ProjectsRepository>((ref) => ProjectsRepository(ref.watch(apiClientProvider)));

final projectsListProvider =
    FutureProvider.autoDispose.family<({List<Project> projects, int total}), String?>(
  (ref, status) => ref.watch(projectsRepositoryProvider).list(status: status),
);

final projectDetailProvider = FutureProvider.autoDispose.family<Project, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).get(id),
);

final projectFinancialSummaryProvider = FutureProvider.autoDispose.family<FinancialSummary, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).financialSummary(id),
);

final projectExpensesProvider = FutureProvider.autoDispose.family<List<Expense>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).expenses(id),
);

final projectTasksProvider = FutureProvider.autoDispose.family<List<ProjectTask>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).tasks(id),
);

final projectPhotosProvider = FutureProvider.autoDispose.family<List<ProjectPhoto>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).photos(id),
);

final projectFilesProvider = FutureProvider.autoDispose.family<List<ProjectFile>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).files(id),
);
