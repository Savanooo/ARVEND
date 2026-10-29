import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../core/api/api_client.dart';
import '../../../../core/api/api_providers.dart';
import '../../../../core/files/device_picker.dart';
import '../../../../core/files/local_documents.dart' show kProjectPhotoCacheDirectory;
import '../../data/project_photo_cache.dart';
import '../../domain/expense_attachment.dart';

/// Masraf fişi / belgesi uçları (backend migration 0076). Projeli ve genel
/// (projesiz) masrafta aynı dört uç; [projectId] boşsa genel masraf
/// (`/expenses/general/{id}/attachments`), ProjectsRepository'nin masraf
/// uçlarıyla aynı kural.
class ExpenseAttachmentsRepository {
  ExpenseAttachmentsRepository(this._client);
  final ApiClient _client;

  static String basePath(String projectId, String expenseId) => projectId.isEmpty
      ? '/expenses/general/$expenseId/attachments'
      : '/projects/$projectId/expenses/$expenseId/attachments';

  Future<List<ExpenseAttachment>> list(String projectId, String expenseId) async {
    final json = await _client.get<Map<String, dynamic>>(basePath(projectId, expenseId));
    return (json['attachments'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(ExpenseAttachment.fromJson)
        .toList();
  }

  /// İçerik ApiClient'ın çerezli Dio örneğinden gelir -- `Image.network`
  /// oturum çerezini taşımaz, 401'e düşerdi (bkz. ApiClient.getBytes).
  Future<Uint8List> bytes(String projectId, String expenseId, String attachmentId) =>
      _client.getBytes('${basePath(projectId, expenseId)}/$attachmentId/content');

  /// Multipart alan adı `file` (25 MiB sınırı çağıranda ön-denetlenir). Aynı
  /// içerik masrafta zaten varsa sunucu mevcut kaydı döner (200) -- yeniden
  /// deneme mükerrer belge açmaz.
  Future<ExpenseAttachment> upload(
    String projectId,
    String expenseId, {
    required String filePath,
    required String fileName,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final form = FormData.fromMap({'file': await MultipartFile.fromFile(filePath, filename: fileName)});
    final json = await _client.upload<Map<String, dynamic>>(
      basePath(projectId, expenseId),
      form,
      onSendProgress: onSendProgress,
    );
    return ExpenseAttachment.fromJson(json);
  }

  /// Kalıcı silme (sunucuda satır + dosya).
  Future<void> delete(String projectId, String expenseId, String attachmentId) =>
      _client.delete<void>('${basePath(projectId, expenseId)}/$attachmentId');
}

final expenseAttachmentsRepositoryProvider = Provider<ExpenseAttachmentsRepository>(
  (ref) => ExpenseAttachmentsRepository(ref.watch(apiClientProvider)),
);

/// Belge içeriklerinin cihaz önbelleği. Belge değişmez (yeni yükleme = yeni
/// kimlik, silme kalıcı), şantiye fotoğraflarıyla aynı mantık: bir kez inen
/// bayt diske yazılır. Dizin fotoğraf önbelleğinin altındadır ki çıkışta
/// (LocalUserFiles) onunla birlikte silinsin -- ortak şantiye telefonunda
/// sonraki kişi öncekinin fişlerini bulmasın.
final expenseAttachmentCacheProvider = Provider<ProjectPhotoCache>(
  (ref) => ProjectPhotoCache(
    directory: () async {
      try {
        final tmp = await getTemporaryDirectory();
        return Directory('${tmp.path}/$kProjectPhotoCacheDirectory/masraf-belgeleri');
      } catch (_) {
        return null;
      }
    },
  ),
);

typedef ExpenseAttachmentKey = ({String projectId, String expenseId, String attachmentId});

/// Küçük resim ve tam ekran aynı baytı paylaşır (ikinci ağ isteği yok).
final expenseAttachmentBytesProvider = FutureProvider.autoDispose.family<Uint8List, ExpenseAttachmentKey>((
  ref,
  key,
) async {
  final cache = ref.watch(expenseAttachmentCacheProvider);
  final cached = await cache.read(key.attachmentId);
  if (cached != null) return cached;
  final bytes = await ref
      .watch(expenseAttachmentsRepositoryProvider)
      .bytes(key.projectId, key.expenseId, key.attachmentId);
  unawaited(cache.write(key.attachmentId, bytes));
  return bytes;
});

/// Masraf kaydedildi ama yüklenemeyen belgeler, masraf kimliğine göre (bu
/// oturum boyunca). Masraf formu ekler; masraf ayrıntısı "Tekrar dene" ile
/// yükler ya da "Vazgeç" ile bırakır. Dosyalar seçicinin geçici kopyalarıdır;
/// çıkışta (LocalUserFiles) silinir, liste de oturumla gider.
class FailedExpenseUploads extends Notifier<Map<String, List<PickedDeviceFile>>> {
  @override
  Map<String, List<PickedDeviceFile>> build() => const {};

  void add(String expenseId, List<PickedDeviceFile> files) {
    if (files.isEmpty) return;
    state = {
      ...state,
      expenseId: [...?state[expenseId], ...files],
    };
  }

  void remove(String expenseId, PickedDeviceFile file) {
    final rest = [...?state[expenseId]]..remove(file);
    state = {...state, expenseId: rest}..removeWhere((_, v) => v.isEmpty);
  }
}

final failedExpenseUploadsProvider = NotifierProvider<FailedExpenseUploads, Map<String, List<PickedDeviceFile>>>(
  FailedExpenseUploads.new,
);
