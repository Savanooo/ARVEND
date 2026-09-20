/// backend `notificationResponse` (bkz. notification_handler.go). `body`
/// ve `title` ASLA tutar veya taşeron/tedarikçi/müşteri adı gibi hassas
/// ticari veri içermez -- yalnızca varlık numarası/başlığı gibi nötr bir
/// referans taşır. `actionTarget`, backend'in ÜRETTİĞİ, mobil app_router
/// ile 1:1 eşleşen tam bir yol (ör. "/projeler/{id}/gorevler/{taskId}")
/// -- istemci kendi yol inşa etmez, olduğu gibi context.push edilir.
class AppNotification {
  final String id;
  final String type;
  final String title;
  final String body;
  final String entityType;
  final String? entityId;
  final String? projectId;
  final String actionTarget;
  final String? readAt;
  final String createdAt;

  const AppNotification({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.entityType,
    this.entityId,
    this.projectId,
    required this.actionTarget,
    this.readAt,
    required this.createdAt,
  });

  bool get isUnread => readAt == null;

  factory AppNotification.fromJson(Map<String, dynamic> json) => AppNotification(
        id: json['id'] as String,
        type: json['type'] as String,
        title: json['title'] as String,
        body: json['body'] as String,
        entityType: json['entity_type'] as String,
        entityId: json['entity_id'] as String?,
        projectId: json['project_id'] as String?,
        actionTarget: json['action_target'] as String? ?? '',
        readAt: json['read_at'] as String?,
        createdAt: json['created_at'] as String,
      );
}

class NotificationsPage {
  const NotificationsPage({required this.notifications, required this.total});

  final List<AppNotification> notifications;
  final int total;
}
