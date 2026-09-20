import '../../../core/api/api_client.dart';
import '../domain/notification.dart';

class NotificationsRepository {
  NotificationsRepository(this._client);
  final ApiClient _client;

  Future<NotificationsPage> list({int page = 1, int limit = 50}) async {
    final json = await _client.get<Map<String, dynamic>>('/notifications', query: {
      'page': page,
      'limit': limit,
    });
    final notifications =
        (json['notifications'] as List).cast<Map<String, dynamic>>().map(AppNotification.fromJson).toList();
    return NotificationsPage(notifications: notifications, total: json['total'] as int);
  }

  Future<int> unreadCount() async {
    final json = await _client.get<Map<String, dynamic>>('/notifications/unread-count');
    return json['unread_count'] as int;
  }

  Future<void> markRead(String id) => _client.post<void>('/notifications/$id/read');

  Future<void> markAllRead() => _client.post<void>('/notifications/read-all');
}
