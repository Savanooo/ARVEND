import 'ops_dates.dart';

/// Planlama aşaması durumları -- backend `domain.ScheduleStatus*` ve
/// `project_schedule_items.status` CHECK kısıtıyla BİREBİR. Backend'de bir
/// geçiş grafiği YOK (her durum her duruma geçebilir, web de düz bir
/// seçici kullanıyor); mobil de kendi kısıtlamasını İCAT ETMEZ.
abstract final class ScheduleStatus {
  static const planned = 'planned';
  static const active = 'active';
  static const completed = 'completed';
  static const cancelled = 'cancelled';

  static const values = [planned, active, completed, cancelled];

  /// Web `SCHEDULE_STATUS_LABELS` ile aynı metinler.
  static const labels = {
    planned: 'Planlandı',
    active: 'Devam Ediyor',
    completed: 'Tamamlandı',
    cancelled: 'İptal',
  };

  static String label(String status) => labels[status] ?? status;
}

/// `GET /projects/{id}/schedule` satırı (backend `scheduleItemResponse`).
/// Sıra backend'indir: `sort_order ASC, start_date ASC NULLS LAST,
/// created_at ASC` -- mobil yeniden sıralamaz.
class ScheduleItem {
  const ScheduleItem({
    required this.id,
    required this.name,
    this.description = '',
    this.startDate,
    this.endDate,
    this.status = ScheduleStatus.planned,
    this.sortOrder = 0,
    this.taskCount = 0,
    this.completedTaskCount = 0,
  });

  final String id;
  final String name;
  final String description;

  /// "YYYY-MM-DD" ya da null.
  final String? startDate;
  final String? endDate;
  final String status;
  final int sortOrder;

  /// Bu aşamaya bağlı görev sayıları -- sunucu sayar.
  final int taskCount;
  final int completedTaskCount;

  factory ScheduleItem.fromJson(Map<String, dynamic> json) => ScheduleItem(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        startDate: json['start_date'] as String?,
        endDate: json['end_date'] as String?,
        status: json['status'] as String? ?? ScheduleStatus.planned,
        sortOrder: (json['sort_order'] as num?)?.toInt() ?? 0,
        taskCount: (json['task_count'] as num?)?.toInt() ?? 0,
        completedTaskCount: (json['completed_task_count'] as num?)?.toInt() ?? 0,
      );

  /// Henüz kapanmamış (planlandı / devam ediyor) aşama.
  bool get isOpen => status == ScheduleStatus.planned || status == ScheduleStatus.active;

  /// Başlangıç ve bitiş ikisi de varsa iki uç dahil gün sayısı.
  int? get durationDays {
    final start = parseDay(startDate);
    final end = parseDay(endDate);
    if (start == null || end == null) return null;
    final days = daysBetween(start, end) + 1;
    return days > 0 ? days : null;
  }

  /// Gecikme: açık (planlandı/devam ediyor) bir aşamanın bitiş tarihi
  /// BUGÜNDEN (İstanbul günü) önce -- ana sayfanın "iş programı kalemi
  /// gecikti" kuralıyla BİREBİR aynı (backend dashboard.sql
  /// `milestones_overdue`). Liste ucu bu alan için `is_overdue` döndürmez
  /// (görevlerin aksine); kural yalnızca gösterim içindir.
  bool isOverdue(DateTime today) => overdueDays(today) > 0;

  /// Bitiş tarihinden bu yana geçen gün (gecikmiyorsa 0).
  int overdueDays(DateTime today) {
    if (!isOpen) return 0;
    final end = parseDay(endDate);
    if (end == null) return 0;
    final days = daysBetween(end, today);
    return days > 0 ? days : 0;
  }

  /// Görev ilerlemesi yüzdesi (görev yoksa null) -- sunucunun verdiği iki
  /// sayının oranı, yalnızca çubuk çizmek için.
  double? get taskProgressPct => taskCount <= 0 ? null : completedTaskCount * 100 / taskCount;

  /// Durumu değişmiş kopya -- `PUT` tüm alanları yeniden yazdığı için (web
  /// ile aynı) diğer alanlar olduğu gibi gönderilir.
  ScheduleItemInput toInput({String? status}) => ScheduleItemInput(
        name: name,
        description: description,
        startDate: startDate,
        endDate: endDate,
        status: status ?? this.status,
        sortOrder: sortOrder,
      );
}

/// `POST/PUT /projects/{id}/schedule[/{itemId}]` gövdesi (backend
/// `scheduleItemRequest`). `PUT` TÜM alanları yazar -- eksik alan boşa
/// düşer; bu yüzden güncellemede her zaman tam gövde gönderilir.
class ScheduleItemInput {
  const ScheduleItemInput({
    required this.name,
    this.description = '',
    this.startDate,
    this.endDate,
    this.status = ScheduleStatus.planned,
    this.sortOrder = 0,
  });

  final String name;
  final String description;
  final String? startDate;
  final String? endDate;
  final String status;
  final int sortOrder;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'start_date': startDate,
        'end_date': endDate,
        'status': status,
        'sort_order': sortOrder,
      };

  @override
  bool operator ==(Object other) =>
      other is ScheduleItemInput &&
      other.name == name &&
      other.description == description &&
      other.startDate == startDate &&
      other.endDate == endDate &&
      other.status == status &&
      other.sortOrder == sortOrder;

  @override
  int get hashCode => Object.hash(name, description, startDate, endDate, status, sortOrder);
}

/// Planlama özetinin sayıları (liste üstündeki kart).
class ScheduleOverview {
  const ScheduleOverview({
    required this.total,
    required this.byStatus,
    required this.overdue,
    required this.taskTotal,
    required this.taskCompleted,
  });

  factory ScheduleOverview.of(List<ScheduleItem> items, DateTime today) {
    final byStatus = {for (final s in ScheduleStatus.values) s: 0};
    var overdue = 0;
    var taskTotal = 0;
    var taskCompleted = 0;
    for (final item in items) {
      byStatus[item.status] = (byStatus[item.status] ?? 0) + 1;
      if (item.isOverdue(today)) overdue++;
      taskTotal += item.taskCount;
      taskCompleted += item.completedTaskCount;
    }
    return ScheduleOverview(
      total: items.length,
      byStatus: byStatus,
      overdue: overdue,
      taskTotal: taskTotal,
      taskCompleted: taskCompleted,
    );
  }

  final int total;
  final Map<String, int> byStatus;
  final int overdue;
  final int taskTotal;
  final int taskCompleted;

  int count(String status) => byStatus[status] ?? 0;
}
