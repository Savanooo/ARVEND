import '../../projects/domain/project.dart';

/// Görev listesi filtreleri -- Faz 7'nin backend uçlarının HİÇBİRİ
/// öncelik/gecikme/proje/metin araması parametresi SUNMAZ (yalnızca
/// `/tasks/mine`'ın `status` parametresi sunucu tarafındadır) -- bu yüzden
/// bu fonksiyonlar TAMAMEN istemci tarafında, ZATEN çekilmiş TEK liste
/// üzerinde çalışır; yeni bir ağ isteği İCAT ETMEZLER. Saf fonksiyonlar
/// olarak ayrıldı ki hem `_OperationsTab` hem `TasksScreen` AYNI mantığı
/// paylaşsın ve doğrudan test edilebilsin.

/// Proje-kapsamlı görev sekmesindeki durum segmenti.
enum TaskStatusFilter { all, open, completed }

bool taskMatchesStatusFilter(ProjectTask task, TaskStatusFilter filter) => switch (filter) {
      TaskStatusFilter.all => true,
      TaskStatusFilter.open => task.status == ProjectTask.statusTodo || task.status == ProjectTask.statusInProgress,
      TaskStatusFilter.completed => task.status == ProjectTask.statusCompleted,
    };

/// Gecikme + öncelik + proje filtreleri -- her ikisi de opsiyonel, null
/// verilirse o eksende hiçbir şey elenmez.
bool taskMatchesCommonFilters(
  ProjectTask task, {
  required bool overdueOnly,
  String? priority,
}) {
  if (overdueOnly && !task.isOverdue) return false;
  if (priority != null && task.priority != priority) return false;
  return true;
}

/// `TasksScreen` (global "Görevlerim") için ayrıca proje + serbest metin
/// arama filtresi -- başlık VEYA proje adında (büyük/küçük harf duyarsız)
/// alt dize eşleşmesi.
bool myTaskMatchesFilters(
  ProjectTask task,
  String projectId,
  String projectName, {
  required bool overdueOnly,
  String? priority,
  String? projectFilter,
  String searchQuery = '',
}) {
  if (!taskMatchesCommonFilters(task, overdueOnly: overdueOnly, priority: priority)) return false;
  if (projectFilter != null && projectId != projectFilter) return false;
  final q = searchQuery.trim().toLowerCase();
  if (q.isNotEmpty && !task.title.toLowerCase().contains(q) && !projectName.toLowerCase().contains(q)) {
    return false;
  }
  return true;
}
