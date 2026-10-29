import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/api/api_client.dart';
import '../domain/chat_message.dart';

/// Firma Grubu uçları (backend router.go "/organization/chat"). Kişi ve firma
/// oturumdan gelir; istek gövdesinde yazar YOK.
class ChatRepository {
  ChatRepository(this._client);
  final ApiClient _client;

  static const _base = '/organization/chat';

  /// Parametresiz: en yeni sayfa. [before]: o numaradan eskiler. [after]:
  /// yoklama (o numaradan sonrakiler; [changedSince] ile bu arada silinenler).
  Future<ChatPage> list({int? before, int? after, String? changedSince, int? limit}) async {
    final json = await _client.get<Map<String, dynamic>>('$_base/messages', query: {
      'before': ?before,
      'after': ?after,
      'changed_since': ?changedSince,
      'limit': ?limit,
    });
    return ChatPage.fromJson(json);
  }

  /// [clientId]: "Tekrar dene" aynı mesajı ikinci kez yazmasın diye mesajın
  /// telefonda üretilen kimliği (sunucu aynı kimlikte ilk kaydı döner).
  Future<ChatMessage> send({required String text, required String clientId}) async {
    final json = await _client.post<Map<String, dynamic>>('$_base/messages', data: {'text': text, 'client_id': clientId});
    return ChatMessage.fromJson(json);
  }

  Future<ChatMessage> sendPhoto({
    required String filePath,
    required String fileName,
    required String clientId,
    String text = '',
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, filename: fileName),
      'text': text,
      'client_id': clientId,
    });
    final json = await _client.upload<Map<String, dynamic>>('$_base/messages/photo', form, onSendProgress: onSendProgress);
    return ChatMessage.fromJson(json);
  }

  /// Yanıt mesajın silinmiş hali.
  Future<ChatMessage> delete(String messageId) async {
    final json = await _client.delete<Map<String, dynamic>>('$_base/messages/$messageId');
    return ChatMessage.fromJson(json);
  }

  /// Kimlik doğrulamalı indirme (çerezler ApiClient'ta; Image.network
  /// kullanılamaz).
  Future<Uint8List> photoBytes(String messageId) => _client.getBytes('$_base/messages/$messageId/photo');

  Future<ChatStatus> status() async =>
      ChatStatus.fromJson(await _client.get<Map<String, dynamic>>('$_base/status'));

  Future<ChatStatus> markRead(int seq) async =>
      ChatStatus.fromJson(await _client.post<Map<String, dynamic>>('$_base/read', data: {'seq': seq}));

  Future<ChatStatus> setMuted(bool muted) async =>
      ChatStatus.fromJson(await _client.put<Map<String, dynamic>>('$_base/mute', data: {'muted': muted}));
}
