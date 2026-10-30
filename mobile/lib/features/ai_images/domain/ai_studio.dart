/// Yapay Zekâ Stüdyo (bkz. mobile/API_CONTRACT.md "Yapay Zekâ Stüdyo"):
/// şantiyeden/projeden bağımsız görsel oluşturma ve telefondaki bir
/// fotoğrafı düzenleme. Sahibin isteği: "ayrı bir menü, şantiye/proje
/// içinde değil". Görseller kişinindir; istenirse sonradan bir projeye
/// eklenir. İzin ve aylık hak proje görselleriyle ortak (ai.images.use,
/// GET /ai/status).
library;

import 'ai_image.dart';

/// Diğer > İş Araçları ve Ana Sayfa hızlı işleminin açtığı ekran.
const kAiStudioRoute = '/diger/yapay-zeka';
const kAiStudioTitle = 'Yapay Zekâ Stüdyo';

/// "Yeni görsel oluştur" için dokununca alana yazılan örnekler.
const kAiGenerateExamples = [
  'Modern salon, ahşap parke, büyük pencere',
  'Banyo seramik, duşakabin, beyaz dolap',
  'Mutfak dolapları beyaz, granit tezgâh',
];

/// Görsellerim'in kapsamı: kişinin kendi görselleri ya da (yalnızca
/// Sahip/Yönetici) firmadaki herkesinki.
enum AiStudioScope {
  mine('mine', 'Benimkiler'),
  firm('firm', 'Firmadakiler');

  const AiStudioScope(this.wire, this.label);
  final String wire;
  final String label;
}

/// Projeye eklerken seçilen aşama (proje fotoğraflarıyla aynı kodlar).
const kAiStudioStages = [
  (code: 'before', label: 'Önce'),
  (code: 'progress', label: 'Süreç'),
  (code: 'after', label: 'Sonra'),
];

class AiStudioJob {
  final String id;
  final String kind;
  final String status;

  /// Sunucunun Türkçe nedeni (yalnızca failed); yoksa boş.
  final String error;
  final String prompt;
  final String? studioImageId;
  final String createdAt;

  const AiStudioJob({
    required this.id,
    required this.kind,
    required this.status,
    required this.error,
    required this.prompt,
    required this.createdAt,
    this.studioImageId,
  });

  bool get isActive => status == AiJobStatus.queued || status == AiJobStatus.running;

  factory AiStudioJob.fromJson(Map<String, dynamic> json) => AiStudioJob(
        id: json['id'] as String,
        kind: json['kind'] as String? ?? '',
        status: json['status'] as String? ?? AiJobStatus.queued,
        error: json['error'] as String? ?? '',
        prompt: json['prompt'] as String? ?? '',
        studioImageId: json['studio_image_id'] as String?,
        createdAt: json['created_at'] as String? ?? '',
      );

  /// İş izleyicisi (AiImageJobsController) proje işleriyle aynı haritada
  /// tutar: projectId boş + [AiImageJob.studio] = stüdyo işi.
  AiImageJob toTracked() => AiImageJob(
        id: id,
        projectId: '',
        kind: kind,
        prompt: prompt,
        status: status,
        error: error,
        createdAt: createdAt,
        resultPhotoId: studioImageId,
        studio: true,
      );
}

/// Görselin eklendiği proje (aynı görsel birden çok projeye eklenebilir).
class AiStudioImageProject {
  final String projectId;
  final String projectName;
  final String projectPhotoId;

  const AiStudioImageProject({required this.projectId, required this.projectName, required this.projectPhotoId});

  factory AiStudioImageProject.fromJson(Map<String, dynamic> json) => AiStudioImageProject(
        projectId: json['project_id'] as String? ?? '',
        projectName: json['project_name'] as String? ?? '',
        projectPhotoId: json['project_photo_id'] as String? ?? '',
      );
}

class AiStudioImage {
  final String id;
  final String kind;
  final String prompt;
  final String createdAt;
  final String userId;
  final String userName;
  final String mime;
  final int sizeBytes;
  final List<AiStudioImageProject> projects;

  const AiStudioImage({
    required this.id,
    required this.kind,
    required this.prompt,
    required this.createdAt,
    this.userId = '',
    this.userName = '',
    this.mime = 'image/jpeg',
    this.sizeBytes = 0,
    this.projects = const [],
  });

  factory AiStudioImage.fromJson(Map<String, dynamic> json) => AiStudioImage(
        id: json['id'] as String,
        kind: json['kind'] as String? ?? '',
        prompt: json['prompt'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
        userId: json['user_id'] as String? ?? '',
        userName: json['user_name'] as String? ?? '',
        mime: json['mime'] as String? ?? 'image/jpeg',
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        projects: (json['projects'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(AiStudioImageProject.fromJson)
            .toList(),
      );

  AiStudioImage withProject(AiStudioImageProject project) => AiStudioImage(
        id: id,
        kind: kind,
        prompt: prompt,
        createdAt: createdAt,
        userId: userId,
        userName: userName,
        mime: mime,
        sizeBytes: sizeBytes,
        projects: [
          for (final p in projects)
            if (p.projectId != project.projectId) p,
          project,
        ],
      );
}

/// GET /ai/studio/images'in bir sayfası.
class AiStudioPage {
  final List<AiStudioImage> images;
  final List<AiStudioJob> pendingJobs;
  final String? nextBefore;

  const AiStudioPage({required this.images, required this.pendingJobs, this.nextBefore});

  factory AiStudioPage.fromJson(Map<String, dynamic> json) => AiStudioPage(
        images: (json['images'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(AiStudioImage.fromJson)
            .toList(),
        pendingJobs: (json['pending_jobs'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(AiStudioJob.fromJson)
            .toList(),
        nextBefore: json['next_before'] as String?,
      );
}
