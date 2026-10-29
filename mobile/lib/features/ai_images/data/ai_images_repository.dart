import '../../../core/api/api_client.dart';
import '../domain/ai_image.dart';

class AiImagesRepository {
  AiImagesRepository(this._client);
  final ApiClient _client;

  Future<AiImageStatus> status() async {
    final json = await _client.get<Map<String, dynamic>>('/ai/status');
    return AiImageStatus.fromJson(json);
  }

  /// İş "sırada" açılır, görsel arka planda hazırlanır (202). 429'da
  /// ApiException.body'de `remaining` gelir; metin zaten Türkçe.
  Future<({AiImageJob job, AiImageQuota? quota})> createJob(
    String projectId, {
    required String kind,
    String prompt = '',
    String? sourcePhotoId,
  }) async {
    final json = await _client.post<Map<String, dynamic>>('/projects/$projectId/ai-image-jobs', data: {
      'kind': kind,
      'prompt': prompt,
      'source_photo_id': ?sourcePhotoId,
    });
    final quota = json['quota'];
    return (
      job: AiImageJob.fromJson(json['job'] as Map<String, dynamic>),
      quota: quota is Map<String, dynamic> ? AiImageQuota.fromJson(quota) : null,
    );
  }

  Future<AiImageJob> job(String projectId, String jobId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/ai-image-jobs/$jobId');
    return AiImageJob.fromJson(json);
  }

  /// Kişinin bu projedeki son işleri (en yenisi önce).
  Future<List<AiImageJob>> jobs(String projectId) async {
    final json = await _client.get<Map<String, dynamic>>('/projects/$projectId/ai-image-jobs');
    return (json['jobs'] as List).cast<Map<String, dynamic>>().map(AiImageJob.fromJson).toList();
  }
}
