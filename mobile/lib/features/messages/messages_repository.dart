import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_providers.dart';

/// Duyuru (firma yöneticisi -> kendi ekibi) ve öneri (herkes -> ARVEND
/// ekibi). Backend: POST /announcements, POST /feedback.
class MessagesRepository {
  MessagesRepository(this._client);
  final ApiClient _client;

  /// Kaç kişiye gittiğini döner.
  Future<int> sendAnnouncement({required String title, required String body}) async {
    final json = await _client.post<Map<String, dynamic>>('/announcements', data: {'title': title, 'body': body});
    return (json['recipients'] as num?)?.toInt() ?? 0;
  }

  Future<void> sendFeedback({required String category, required String body, String appVersion = ''}) async {
    await _client.post<Map<String, dynamic>>('/feedback', data: {
      'category': category,
      'body': body,
      'app_version': appVersion,
    });
  }
}

final messagesRepositoryProvider = Provider<MessagesRepository>((ref) => MessagesRepository(ref.watch(apiClientProvider)));
