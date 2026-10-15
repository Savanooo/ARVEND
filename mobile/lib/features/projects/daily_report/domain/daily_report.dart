import 'package:flutter/material.dart';

/// Günlük şantiye raporu (backend migration 0071): proje başına günde bir
/// rapor -- hava, kendi ekibimiz ve taşeronlardan kaç kişi, yapılan işler,
/// sorunlar, gelen malzeme, notlar. O gün tamamlanan görevler ve çekilen
/// fotoğraflar sunucudan tarihle gelir (ayrıca girilmez). "Gönder"
/// yöneticilere bildirir; PDF paylaşılır.

/// Hava durumu anahtarları (backend CHECK ile aynı) -> etiket.
const kDailyReportWeathers = <String, String>{
  'sunny': 'Güneşli',
  'cloudy': 'Bulutlu',
  'rainy': 'Yağmurlu',
  'snowy': 'Karlı',
  'windy': 'Rüzgârlı',
};

IconData dailyReportWeatherIcon(String weather) => switch (weather) {
      'sunny' => Icons.wb_sunny_outlined,
      'cloudy' => Icons.cloud_outlined,
      'rainy' => Icons.umbrella_outlined,
      'snowy' => Icons.ac_unit,
      'windy' => Icons.air,
      _ => Icons.help_outline,
    };

const kDailyReportDraft = 'draft';
const kDailyReportSubmitted = 'submitted';

/// Raporda sahadaki bir taşeron (Taşeronlar kartı) ve o gün kaç kişi.
class DailyReportSubcontractor {
  const DailyReportSubcontractor({
    required this.supplierId,
    required this.name,
    this.specialty = '',
    required this.workers,
    this.workNote = '',
  });

  final String supplierId;
  final String name;
  final String specialty;
  final int workers;
  final String workNote;

  DailyReportSubcontractor copyWith({int? workers, String? workNote}) => DailyReportSubcontractor(
        supplierId: supplierId,
        name: name,
        specialty: specialty,
        workers: workers ?? this.workers,
        workNote: workNote ?? this.workNote,
      );

  factory DailyReportSubcontractor.fromJson(Map<String, dynamic> json) => DailyReportSubcontractor(
        supplierId: json['supplier_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        specialty: json['specialty'] as String? ?? '',
        workers: (json['workers'] as num?)?.toInt() ?? 0,
        workNote: json['work_note'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'supplier_id': supplierId, 'workers': workers, 'work_note': workNote};
}

class DailyReportTask {
  const DailyReportTask({required this.id, required this.title, required this.assignedName});

  final String id;
  final String title;
  final String assignedName;

  factory DailyReportTask.fromJson(Map<String, dynamic> json) => DailyReportTask(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        assignedName: json['assigned_name'] as String? ?? '',
      );
}

class DailyReportPhoto {
  const DailyReportPhoto({required this.id, required this.stage, required this.description});

  final String id;
  final String stage;
  final String description;

  factory DailyReportPhoto.fromJson(Map<String, dynamic> json) => DailyReportPhoto(
        id: json['id'] as String? ?? '',
        stage: json['stage'] as String? ?? '',
        description: json['description'] as String? ?? '',
      );
}

/// GET /projects/{id}/daily-reports/{date}. [exists] false ise gün henüz
/// yazılmamış; otomatik alanlar ([suggestedOwnWorkers], [completedTasks],
/// [photos]) yine doludur.
class DailyReport {
  const DailyReport({
    required this.exists,
    required this.id,
    required this.projectId,
    required this.reportDate,
    required this.weather,
    required this.temperatureC,
    required this.ownWorkers,
    required this.workDone,
    required this.issues,
    required this.materials,
    required this.notes,
    required this.status,
    required this.submittedAt,
    required this.submittedByName,
    required this.createdByName,
    required this.updatedAt,
    required this.subcontractors,
    required this.suggestedOwnWorkers,
    required this.completedTasks,
    required this.photos,
    this.subcontractorOptions = const [],
  });

  final bool exists;
  final String id;
  final String projectId;

  /// YYYY-AA-GG.
  final String reportDate;
  final String weather;
  final int? temperatureC;
  final int ownWorkers;
  final String workDone;
  final String issues;
  final String materials;
  final String notes;
  final String status;
  final String? submittedAt;
  final String submittedByName;
  final String createdByName;
  final String? updatedAt;
  final List<DailyReportSubcontractor> subcontractors;
  final int suggestedOwnWorkers;
  final List<DailyReportTask> completedTasks;
  final List<DailyReportPhoto> photos;

  /// Formun taşeron seçicisi: projeye bağlı ya da projenin önceki
  /// raporlarında geçen aktif kartlar (saha şefinin tedarikçi listesini
  /// okuma izni yok).
  final List<DailyReportSubcontractor> subcontractorOptions;

  bool get isSubmitted => status == kDailyReportSubmitted;
  int get subcontractorWorkers => subcontractors.fold(0, (sum, s) => sum + s.workers);
  int get totalWorkers => ownWorkers + subcontractorWorkers;

  factory DailyReport.fromJson(Map<String, dynamic> json) => DailyReport(
        exists: json['exists'] as bool? ?? false,
        id: json['id'] as String? ?? '',
        projectId: json['project_id'] as String? ?? '',
        reportDate: json['report_date'] as String? ?? '',
        weather: json['weather'] as String? ?? '',
        temperatureC: (json['temperature_c'] as num?)?.toInt(),
        ownWorkers: (json['own_workers'] as num?)?.toInt() ?? 0,
        workDone: json['work_done'] as String? ?? '',
        issues: json['issues'] as String? ?? '',
        materials: json['materials'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
        status: json['status'] as String? ?? kDailyReportDraft,
        submittedAt: json['submitted_at'] as String?,
        submittedByName: json['submitted_by_name'] as String? ?? '',
        createdByName: json['created_by_name'] as String? ?? '',
        updatedAt: json['updated_at'] as String?,
        subcontractors: _list(json['subcontractors'], DailyReportSubcontractor.fromJson),
        suggestedOwnWorkers: (json['suggested_own_workers'] as num?)?.toInt() ?? 0,
        completedTasks: _list(json['completed_tasks'], DailyReportTask.fromJson),
        photos: _list(json['photos'], DailyReportPhoto.fromJson),
        subcontractorOptions: _list(json['subcontractor_options'], DailyReportSubcontractor.fromJson),
      );
}

/// PUT gövdesi.
class DailyReportInput {
  const DailyReportInput({
    required this.weather,
    required this.temperatureC,
    required this.ownWorkers,
    required this.workDone,
    required this.issues,
    required this.materials,
    required this.notes,
    required this.subcontractors,
  });

  final String weather;
  final int? temperatureC;
  final int ownWorkers;
  final String workDone;
  final String issues;
  final String materials;
  final String notes;
  final List<DailyReportSubcontractor> subcontractors;

  Map<String, dynamic> toJson() => {
        'weather': weather,
        'temperature_c': temperatureC,
        'own_workers': ownWorkers,
        'work_done': workDone,
        'issues': issues,
        'materials': materials,
        'notes': notes,
        'subcontractors': [for (final s in subcontractors) s.toJson()],
      };
}

/// Rapor listesinin satırı.
class DailyReportListItem {
  const DailyReportListItem({
    required this.id,
    required this.reportDate,
    required this.weather,
    required this.temperatureC,
    required this.ownWorkers,
    required this.subcontractorWorkers,
    required this.status,
    required this.workDone,
    required this.createdByName,
    required this.photoCount,
  });

  final String id;
  final String reportDate;
  final String weather;
  final int? temperatureC;
  final int ownWorkers;
  final int subcontractorWorkers;
  final String status;
  final String workDone;
  final String createdByName;
  final int photoCount;

  bool get isSubmitted => status == kDailyReportSubmitted;
  int get totalWorkers => ownWorkers + subcontractorWorkers;

  factory DailyReportListItem.fromJson(Map<String, dynamic> json) => DailyReportListItem(
        id: json['id'] as String? ?? '',
        reportDate: json['report_date'] as String? ?? '',
        weather: json['weather'] as String? ?? '',
        temperatureC: (json['temperature_c'] as num?)?.toInt(),
        ownWorkers: (json['own_workers'] as num?)?.toInt() ?? 0,
        subcontractorWorkers: (json['subcontractor_workers'] as num?)?.toInt() ?? 0,
        status: json['status'] as String? ?? kDailyReportDraft,
        workDone: json['work_done'] as String? ?? '',
        createdByName: json['created_by_name'] as String? ?? '',
        photoCount: (json['photo_count'] as num?)?.toInt() ?? 0,
      );
}

/// GET /projects/{id}/daily-reports -- raporlar (en yeni gün önce) ve
/// sunucunun İstanbul'a göre bugünü.
class DailyReportList {
  const DailyReportList({required this.reports, required this.today});

  final List<DailyReportListItem> reports;
  final String today;

  DailyReportListItem? get todays => reports.where((r) => r.reportDate == today).firstOrNull;

  factory DailyReportList.fromJson(Map<String, dynamic> json) => DailyReportList(
        reports: _list(json['reports'], DailyReportListItem.fromJson),
        today: json['today'] as String? ?? '',
      );
}

List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) fromJson) =>
    (raw as List? ?? const []).cast<Map<String, dynamic>>().map(fromJson).toList();
