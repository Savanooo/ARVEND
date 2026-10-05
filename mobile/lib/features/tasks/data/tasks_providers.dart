import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../projects/data/projects_providers.dart';
import '../../projects/domain/project.dart';

typedef ProjectTaskWithProject = (ProjectTask task, String projectId, String projectName);

/// Görev listesi + (yalnızca "Benim" için) hesabın bir personel kaydına
/// bağlı olup olmadığı. Bağlı değilse kişiye görev atanamaz; boş listenin
/// nedeni budur ve ekran bunu söyler.
class TaskListPage {
  const TaskListPage(this.items, {this.linkedEmployee});
  final List<ProjectTaskWithProject> items;

  /// null = bilinmiyor (eski sunucu ya da "Ekip" görünümü).
  final bool? linkedEmployee;
}

/// GET /api/v1/tasks/mine — sunucu tarafında org + proje erişimi ile
/// filtrelenir. Eski O(N) proje döngüsü kaldırıldı. `status`, backend'in
/// desteklediği ham modlardan biridir: "open" (varsayılan, todo+in_progress),
/// "all", veya somut bir durum ("todo"/"in_progress"/"completed"/
/// "cancelled") -- mobil bunun ÜSTÜNE ikinci bir filtre kelime kümesi
/// İCAT ETMEZ.
final myTasksProvider = FutureProvider.autoDispose.family<TaskListPage, String>((ref, status) async {
  final repo = ref.watch(projectsRepositoryProvider);
  final page = await repo.myTasks(status: status);
  return TaskListPage(
    [for (final row in page.tasks) (row.$1, row.$2, row.$3)],
    linkedEmployee: page.linkedEmployee,
  );
});

/// GET /api/v1/tasks/team — "Ekip" görünümü: erişilebilir projelerdeki
/// tüm görevler. Yönetici görevi buradan atar ve takip eder.
final teamTasksProvider = FutureProvider.autoDispose.family<TaskListPage, String>((ref, status) async {
  final repo = ref.watch(projectsRepositoryProvider);
  final rows = await repo.teamTasks(status: status);
  return TaskListPage([for (final row in rows) (row.$1, row.$2, row.$3)]);
});

/// Görevin notları (en yeni önce).
final taskUpdatesProvider = FutureProvider.autoDispose.family<List<TaskUpdate>, ({String projectId, String taskId})>(
  (ref, key) => ref.watch(projectsRepositoryProvider).taskUpdates(key.projectId, key.taskId),
);

/// Görevler ekranında son seçilen görünüm ("mine" / "team"); null =
/// varsayılan (görev atayabilen yönetici için Ekip, diğerleri için Benim).
final tasksScopeProvider = StateProvider<String?>((ref) => null);

/// Bir görev değiştiğinde (oluştur/düzenle/tamamla/not) bütün görev
/// listelerini tazeler.
void invalidateTaskLists(WidgetRef ref) {
  ref.invalidate(myTasksProvider);
  ref.invalidate(teamTasksProvider);
}
