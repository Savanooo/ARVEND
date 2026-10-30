import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/api/api_client.dart';
import '../domain/ai_studio.dart';
import 'ai_images_repository.dart' show aiMaskMultipart;

/// Yapay Zekâ Stüdyo uçları (/ai/studio/*). İzin: ai.images.use.
class AiStudioRepository {
  AiStudioRepository(this._client);
  final ApiClient _client;

  /// İş "sırada" açılır (202). Kaynak ya telefondan yüklenen dosya
  /// ([imagePath]) ya da daha önce üretilmiş bir stüdyo görseli
  /// ([sourceStudioImageId]; sonucu yeniden düzenlemek için, kind=edit);
  /// "generate"de hiçbiri. 429'da ApiException.body'de `remaining` gelir,
  /// metin zaten Türkçe.
  Future<({AiStudioJob job, int? remaining, int? limit})> createJob({
    required String kind,
    String prompt = '',
    String? imagePath,
    String? imageName,
    String? sourceStudioImageId,
    Uint8List? mask,
  }) async {
    final form = FormData.fromMap({
      'kind': kind,
      if (prompt.trim().isNotEmpty) 'prompt': prompt.trim(),
      // Senkron: dosyanın yalnızca boyutu okunur, içeriği gönderilirken akar.
      if (imagePath != null) 'image': MultipartFile.fromFileSync(imagePath, filename: imageName),
      'source_studio_image_id': ?sourceStudioImageId,
      // "Alanı işaretle": yalnızca boyanan alan değişir (kind=edit).
      if (mask != null) 'mask': aiMaskMultipart(mask),
    });
    final json = await _client.upload<Map<String, dynamic>>('/ai/studio/jobs', form);
    return (
      job: AiStudioJob.fromJson(json['job'] as Map<String, dynamic>),
      remaining: (json['remaining'] as num?)?.toInt(),
      limit: (json['limit'] as num?)?.toInt(),
    );
  }

  Future<AiStudioJob> job(String id) async =>
      AiStudioJob.fromJson(await _client.get<Map<String, dynamic>>('/ai/studio/jobs/$id'));

  /// En yenisi önce; [before] bir önceki sayfanın next_before'u.
  Future<AiStudioPage> images({AiStudioScope scope = AiStudioScope.mine, String? before, int limit = 30}) async {
    final json = await _client.get<Map<String, dynamic>>('/ai/studio/images', query: {
      'limit': limit,
      'scope': scope.wire,
      'before': ?before,
    });
    return AiStudioPage.fromJson(json);
  }

  Future<Uint8List> imageBytes(String id) => _client.getBytes('/ai/studio/images/$id/content');

  Future<void> delete(String id) => _client.delete<void>('/ai/studio/images/$id');

  /// Aynı görsel aynı projeye ikinci kez eklenirse sunucu aynı fotoğrafı
  /// döner (idempotent).
  Future<String> addToProject(String id, {required String projectId, required String stage}) async {
    final json = await _client.post<Map<String, dynamic>>(
      '/ai/studio/images/$id/add-to-project',
      data: {'project_id': projectId, 'stage': stage},
    );
    return json['project_photo_id'] as String? ?? '';
  }
}
