/// Firma Grubu (backend migration 0077): firma başına TEK grup -- firmanın
/// çalışanları yazar ve okur, taşeron hesapları grubu hiç görmez. Backend
/// `chatMessageResponse` (organization_chat_handler.go).
library;

/// Grubun izni (backend `domain.PermOrganizationChatUse`).
const kPermOrganizationChatUse = 'organization.chat.use';

/// Push/bildirim türü ve açtığı ekran (backend `domain.NotificationOrganizationChat`,
/// `domain.ChatActionTarget`).
const kChatNotificationType = 'organization_chat';
const kChatRoute = '/diger/firma-grubu';

/// Mesaj metni sınırı (backend `domain.ChatMaxBodyRunes`).
const kChatMaxTextLength = 4000;

class ChatPhoto {
  const ChatPhoto({required this.mimeType, required this.sizeBytes});

  final String mimeType;
  final int sizeBytes;

  factory ChatPhoto.fromJson(Map<String, dynamic> json) => ChatPhoto(
        mimeType: json['mime_type'] as String? ?? '',
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {'mime_type': mimeType, 'size_bytes': sizeBytes};
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.seq,
    this.authorId,
    required this.authorName,
    required this.text,
    this.photo,
    required this.createdAt,
    this.deleted = false,
    this.isOwn = false,
    this.canDelete = false,
  });

  final String id;

  /// Firma içi sıra numarası: sıralama ve yoklama (`after`) bununla.
  final int seq;
  final String? authorId;
  final String authorName;

  /// Silinmiş mesajda boş.
  final String text;

  /// Silinmiş ya da fotoğrafsız mesajda null.
  final ChatPhoto? photo;

  /// RFC3339 (sunucu UTC yazar).
  final String createdAt;
  final bool deleted;

  /// Çağırana göre: sağda çizilir.
  final bool isOwn;

  /// Çağırana göre: uzun basınca "Sil" (kendi mesajı ya da Sahip/Yönetici).
  final bool canDelete;

  DateTime? get createdAtTime => DateTime.tryParse(createdAt);

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        seq: (json['seq'] as num).toInt(),
        authorId: json['author_id'] as String?,
        authorName: json['author_name'] as String? ?? '',
        text: json['text'] as String? ?? '',
        photo: json['photo'] is Map<String, dynamic> ? ChatPhoto.fromJson(json['photo'] as Map<String, dynamic>) : null,
        createdAt: json['created_at'] as String? ?? '',
        deleted: json['deleted'] as bool? ?? false,
        isOwn: json['is_own'] as bool? ?? false,
        canDelete: json['can_delete'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'seq': seq,
        'author_id': authorId,
        'author_name': authorName,
        'text': text,
        'photo': photo?.toJson(),
        'created_at': createdAt,
        'deleted': deleted,
        'is_own': isOwn,
        'can_delete': canDelete,
      };
}

/// GET /organization/chat/messages yanıtı. [messages] HER ZAMAN yeniden
/// eskiye (numara azalan) sıralıdır.
class ChatPage {
  const ChatPage({
    required this.messages,
    this.hasMore = false,
    this.updated = const [],
    this.lastReadSeq = 0,
    this.muted = false,
    this.canModerate = false,
    this.serverTime,
  });

  final List<ChatMessage> messages;

  /// Sorgunun yönünde (before: daha eski, after: daha yeni) daha fazlası var.
  final bool hasMore;

  /// Yoklamada (after + changed_since) elimizdeki aralıkta bu arada silinenler.
  final List<ChatMessage> updated;
  final int lastReadSeq;
  final bool muted;
  final bool canModerate;

  /// Bir sonraki yoklamanın `changed_since`'i.
  final String? serverTime;

  factory ChatPage.fromJson(Map<String, dynamic> json) {
    List<ChatMessage> list(Object? raw) => raw is List
        ? [for (final m in raw.cast<Map<String, dynamic>>()) ChatMessage.fromJson(m)]
        : const [];
    return ChatPage(
      messages: list(json['messages']),
      hasMore: json['has_more'] as bool? ?? false,
      updated: list(json['updated']),
      lastReadSeq: (json['last_read_seq'] as num?)?.toInt() ?? 0,
      muted: json['muted'] as bool? ?? false,
      canModerate: json['can_moderate'] as bool? ?? false,
      serverTime: json['server_time'] as String?,
    );
  }
}

/// GET /organization/chat/status, POST read, PUT mute yanıtı.
class ChatStatus {
  const ChatStatus({required this.unreadCount, required this.muted, required this.lastReadSeq});

  /// Sunucu 1000'de keser; rozet "99+" yazar.
  final int unreadCount;
  final bool muted;
  final int lastReadSeq;

  factory ChatStatus.fromJson(Map<String, dynamic> json) => ChatStatus(
        unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
        muted: json['muted'] as bool? ?? false,
        lastReadSeq: (json['last_read_seq'] as num?)?.toInt() ?? 0,
      );
}

/// Rozet metni: 1..99, sonrası "99+".
String chatBadgeLabel(int count) => count > 99 ? '99+' : '$count';
