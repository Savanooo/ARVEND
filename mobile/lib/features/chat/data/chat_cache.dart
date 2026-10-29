import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/files/local_documents.dart' show kChatCacheDirectory;
import '../domain/chat_message.dart';

/// Firma Grubu'nun cihaz önbelleği (geçici dizinde `firma-grubu/`): son
/// mesajlar ve fotoğraf baytları. Şantiyede bağlantı sık kopar -- ekran
/// açılınca önce son görülen mesajlar gelir, sunucu yanıt vermezse "Bağlantı
/// yok" ile onlar kalır. Gönderilemeyen mesaj SAKLANMAZ (kuyruk yok: ekranda
/// "Tekrar dene" ile durur).
///
/// Kişiye özeldir (dosya adı kullanıcı kimliği) ve çıkışta silinir (bkz.
/// LocalUserFiles): ortak şantiye telefonunda sonraki kişi öncekinin
/// grubunu görmesin. Dizin alınamazsa (test ortamı) sessizce kapalıdır.
class ChatCache {
  ChatCache({Future<Directory?> Function()? directory}) : _directory = directory ?? _defaultDirectory;

  /// Diske yazılan en çok mesaj (en yeniler).
  static const maxMessages = 100;

  final Future<Directory?> Function() _directory;
  Future<Directory?>? _dir;

  static Future<Directory?> _defaultDirectory() async {
    try {
      final tmp = await getTemporaryDirectory();
      return Directory('${tmp.path}/$kChatCacheDirectory');
    } catch (_) {
      return null;
    }
  }

  // Kimlikler UUID'dir; yine de yol parçası olarak yalnızca güvenli
  // karakterler kabul edilir.
  static final _safeId = RegExp(r'^[A-Za-z0-9-]{1,64}$');

  Future<File?> _file(String name) async {
    if (!_safeId.hasMatch(name)) return null;
    final dir = await (_dir ??= _directory());
    return dir == null ? null : File('${dir.path}/$name');
  }

  Future<File?> _photoFile(String messageId) async {
    if (!_safeId.hasMatch(messageId)) return null;
    final dir = await (_dir ??= _directory());
    return dir == null ? null : File('${dir.path}/foto/$messageId');
  }

  /// Kişinin son kaydedilen görünümü; yoksa/okunamazsa null.
  Future<ChatSnapshot?> read(String userId) async {
    try {
      final file = await _file(userId);
      if (file == null || !await file.exists()) return null;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ChatSnapshot.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String userId, ChatSnapshot snapshot) async {
    try {
      final file = await _file(userId);
      if (file == null) return;
      await file.parent.create(recursive: true);
      final partial = File('${file.path}.part');
      await partial.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
      await partial.rename(file.path);
    } catch (_) {
      // Yazılamazsa bir sonraki açılışta sunucudan gelir.
    }
  }

  /// Fotoğrafın içeriği mesaj kimliğine bağlı ve değişmez: bir kez inen
  /// bayt bir daha indirilmez.
  Future<Uint8List?> readPhoto(String messageId) async {
    try {
      final file = await _photoFile(messageId);
      if (file == null || !await file.exists()) return null;
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> writePhoto(String messageId, Uint8List bytes) async {
    try {
      final file = await _photoFile(messageId);
      if (file == null) return;
      await file.parent.create(recursive: true);
      final partial = File('${file.path}.part');
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(file.path);
    } catch (_) {}
  }

  /// Silinen mesajın fotoğrafı telefonda da kalmasın.
  Future<void> removePhoto(String messageId) async {
    try {
      final file = await _photoFile(messageId);
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// Önbelleğe yazılan görünüm: mesajlar (yeniden eskiye) ve grup durumu.
class ChatSnapshot {
  const ChatSnapshot({
    required this.organizationId,
    required this.messages,
    this.muted = false,
    this.canModerate = false,
    this.lastReadSeq = 0,
    this.hasMoreOlder = false,
  });

  /// Kişi başka firmaya geçtiyse (aynı kimlik olmaz ama) eski grup gösterilmez.
  final String organizationId;
  final List<ChatMessage> messages;
  final bool muted;
  final bool canModerate;
  final int lastReadSeq;
  final bool hasMoreOlder;

  factory ChatSnapshot.fromJson(Map<String, dynamic> json) => ChatSnapshot(
        organizationId: json['organization_id'] as String? ?? '',
        messages: [
          for (final m in (json['messages'] as List? ?? const []).cast<Map<String, dynamic>>()) ChatMessage.fromJson(m),
        ],
        muted: json['muted'] as bool? ?? false,
        canModerate: json['can_moderate'] as bool? ?? false,
        lastReadSeq: (json['last_read_seq'] as num?)?.toInt() ?? 0,
        hasMoreOlder: json['has_more_older'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'organization_id': organizationId,
        'messages': [for (final m in messages.take(ChatCache.maxMessages)) m.toJson()],
        'muted': muted,
        'can_moderate': canModerate,
        'last_read_seq': lastReadSeq,
        // Kesilen listede daha eskisi sunucuda var.
        'has_more_older': hasMoreOlder || messages.length > ChatCache.maxMessages,
      };
}

final chatCacheProvider = Provider<ChatCache>((ref) => ChatCache());
