import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/api/api_client.dart';
import '../domain/ai_image.dart';

/// "Alanı işaretle" maskesinin multipart parçası (proje ve Stüdyo ortak).
MultipartFile aiMaskMultipart(Uint8List png) =>
    MultipartFile.fromBytes(png, filename: 'mask.png', contentType: DioMediaType('image', 'png'));

class AiImagesRepository {
  AiImagesRepository(this._client);
  final ApiClient _client;

  Future<AiImageStatus> status() async {
    final json = await _client.get<Map<String, dynamic>>('/ai/status');
    return AiImageStatus.fromJson(json);
  }

  /// İş "sırada" açılır, görsel arka planda hazırlanır (202). 429'da
  /// ApiException.body'de `remaining` gelir; metin zaten Türkçe.
  ///
  /// [mask] ("Alanı işaretle", yalnızca kind=edit): kaynakla aynı boyutta
  /// PNG, değişecek alan saydam. Maske varsa istek multipart gider (dosya
  /// JSON'a girmez); yoksa 1.5.22'deki gibi JSON.
  Future<({AiImageJob job, AiImageQuota? quota})> createJob(
    String projectId, {
    required String kind,
    String prompt = '',
    String? sourcePhotoId,
    Uint8List? mask,
  }) async {
    final path = '/projects/$projectId/ai-image-jobs';
    final fields = {
      'kind': kind,
      'prompt': prompt,
      'source_photo_id': ?sourcePhotoId,
    };
    final json = mask == null
        ? await _client.post<Map<String, dynamic>>(path, data: fields)
        : await _client.upload<Map<String, dynamic>>(
            path,
            FormData.fromMap({...fields, 'mask': aiMaskMultipart(mask)}),
          );
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
