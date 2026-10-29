import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/config/app_config.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/files/device_picker.dart' show PickedDeviceFile;
import '../../auth/domain/user.dart';
import '../domain/chat_message.dart';
import 'chat_cache.dart';
import 'chat_repository.dart';

export 'chat_cache.dart' show chatCacheProvider, ChatCache, ChatSnapshot;

final chatRepositoryProvider = Provider<ChatRepository>((ref) => ChatRepository(ref.watch(apiClientProvider)));

/// Firma Grubu'nu görebilir mi: izin (KATI, fail-closed -- izin listesi
/// yoksa istek atılmaz; izinsiz istek 403 ile izin tazelemeyi tetiklerdi) ve
/// taşeron hesabı değil (sunucu da ona uçları açmaz).
bool canUseChat(User? user) => user != null && !user.isSubcontractor && user.canAccess(kPermOrganizationChatUse);

/// Ana sayfa ve Diğer'deki rozet: okunmamış mesaj sayısı. Grubu
/// göremeyende istek atılmaz (0). Uygulama öne gelince, Firma Grubu
/// bildirimi gelince ve grup okununca tazelenir.
final chatUnreadCountProvider = FutureProvider.autoDispose<int>((ref) async {
  final allowed = ref.watch(authControllerProvider.select((s) => canUseChat(s.valueOrNull)));
  if (!allowed) return 0;
  return (await ref.watch(chatRepositoryProvider).status()).unreadCount;
});

/// Uygulama açıkken Firma Grubu bildirimi geldi (PushWatcher artırır): açık
/// sohbet ekranı beklemeden yoklar.
final chatPushTickProvider = StateProvider<int>((ref) => 0);

/// Fotoğraf baytları: önce cihaz önbelleği, yoksa kimlik doğrulamalı
/// indirme (bkz. ChatCache). Küçük resim ve tam ekran aynı baytı paylaşır.
final chatPhotoBytesProvider = FutureProvider.autoDispose.family<Uint8List, String>((ref, messageId) async {
  final cache = ref.watch(chatCacheProvider);
  final cached = await cache.readPhoto(messageId);
  if (cached != null) return cached;
  final bytes = await ref.watch(chatRepositoryProvider).photoBytes(messageId);
  unawaited(cache.writePhoto(messageId, bytes));
  return bytes;
});

/// Kamera/galeri. Gruba giden fotoğraf telefonda küçültülür (en uzun kenar
/// 1920, JPEG %80): şantiyeden mobil veriyle birkaç yüz KB gider, 25 MB'lık
/// sınıra hiç yaklaşmaz; iPhone'un HEIC'i de JPEG'e döner (sunucu HEIC'i
/// gösteremez). Testler sahtesini verir.
abstract interface class ChatPhotoPicker {
  Future<PickedDeviceFile?> pick(ImageSource source);
}

class PluginChatPhotoPicker implements ChatPhotoPicker {
  const PluginChatPhotoPicker();

  @override
  Future<PickedDeviceFile?> pick(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, maxWidth: 1920, maxHeight: 1920, imageQuality: 80);
    return picked == null ? null : (path: picked.path, name: picked.name, size: null);
  }
}

final chatPhotoPickerProvider = Provider<ChatPhotoPicker>((ref) => const PluginChatPhotoPicker());

// ---------- Sohbet ekranının durumu ----------

enum ChatSendStatus { sending, failed }

/// Telefondan çıkmayı bekleyen mesaj. Kuyruk YOK: gönderilemezse ekranda
/// "Tekrar dene" ile durur, ekrandan çıkınca unutulur (önbelleğe yazılmaz).
class PendingChatMessage {
  const PendingChatMessage({
    required this.clientId,
    required this.text,
    this.photoPath,
    this.photoName,
    required this.createdAt,
    this.status = ChatSendStatus.sending,
    this.error,
    this.progress,
  });

  /// Sunucuya giden client_id: "Tekrar dene" aynı kimlikle gider, yanıtı
  /// yolda kaybolan mesaj ikinci kez yazılmaz.
  final String clientId;
  final String text;
  final String? photoPath;
  final String? photoName;
  final DateTime createdAt;
  final ChatSendStatus status;
  final String? error;

  /// Fotoğraf yüklemesinin ilerlemesi (0..1); bilinmiyorsa null.
  final double? progress;

  bool get isPhoto => photoPath != null;

  PendingChatMessage copyWith({ChatSendStatus? status, String? error, double? progress, bool clearError = false}) =>
      PendingChatMessage(
        clientId: clientId,
        text: text,
        photoPath: photoPath,
        photoName: photoName,
        createdAt: createdAt,
        status: status ?? this.status,
        error: clearError ? null : (error ?? this.error),
        progress: progress,
      );
}

const _unset = Object();

class ChatState {
  const ChatState({
    this.messages = const [],
    this.pending = const [],
    this.initialLoading = true,
    this.loadedFromServer = false,
    this.loadError,
    this.offline = false,
    this.hasMoreOlder = false,
    this.loadingOlder = false,
    this.muted = false,
    this.canModerate = false,
    this.lastReadSeq = 0,
    this.firstUnreadSeq,
  });

  /// Yeniden eskiye (numara azalan) -- ters çevrilmiş listede en yeni altta.
  final List<ChatMessage> messages;

  /// Eskiden yeniye.
  final List<PendingChatMessage> pending;
  final bool initialLoading;

  /// Sunucudan en az bir kez taze sayfa geldi (yoksa gösterilen önbellek).
  final bool loadedFromServer;

  /// Son yükleme/yoklama hatası (gösterilecek bir şey varken bant, yokken
  /// tam ekran hata).
  final Object? loadError;

  /// Son istek bağlantı yüzünden düştü: "Bağlantı yok".
  final bool offline;
  final bool hasMoreOlder;
  final bool loadingOlder;
  final bool muted;
  final bool canModerate;
  final int lastReadSeq;

  /// Ekran açıldığında okunmamış olan ilk (başkasının) mesaj: "Okunmamış
  /// mesajlar" ayracı onun üstünde durur. Ekran açık kaldıkça değişmez.
  final int? firstUnreadSeq;

  int get maxSeq => messages.isEmpty ? 0 : messages.first.seq;
  int get minSeq => messages.isEmpty ? 0 : messages.last.seq;

  ChatState copyWith({
    List<ChatMessage>? messages,
    List<PendingChatMessage>? pending,
    bool? initialLoading,
    bool? loadedFromServer,
    Object? loadError = _unset,
    bool? offline,
    bool? hasMoreOlder,
    bool? loadingOlder,
    bool? muted,
    bool? canModerate,
    int? lastReadSeq,
    Object? firstUnreadSeq = _unset,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        pending: pending ?? this.pending,
        initialLoading: initialLoading ?? this.initialLoading,
        loadedFromServer: loadedFromServer ?? this.loadedFromServer,
        loadError: identical(loadError, _unset) ? this.loadError : loadError,
        offline: offline ?? this.offline,
        hasMoreOlder: hasMoreOlder ?? this.hasMoreOlder,
        loadingOlder: loadingOlder ?? this.loadingOlder,
        muted: muted ?? this.muted,
        canModerate: canModerate ?? this.canModerate,
        lastReadSeq: lastReadSeq ?? this.lastReadSeq,
        firstUnreadSeq: identical(firstUnreadSeq, _unset) ? this.firstUnreadSeq : firstUnreadSeq as int?,
      );
}

/// Bağlantı yüzünden mi düştü (sunucu bir şey demedi).
bool isChatConnectivityError(Object e) =>
    e is ApiException && (e.kind == ApiErrorKind.network || e.kind == ApiErrorKind.timeout);

final _random = Random.secure();

/// Mesajın telefonda üretilen kimliği (UUID v4) -- paket eklemeden.
String newChatClientId() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Sohbet ekranının beyni: önbellekten açılış, en yeni sayfa, yoklama
/// (after + changed_since), eski sayfalar, gönderme/tekrar deneme, silme,
/// sessize alma ve görünürken okundu işaretleme. Zamanlayıcı ve uygulama
/// yaşam döngüsü ekrandadır (ChatScreen); burası yalnızca ne zaman
/// çağrılırsa onu yapar.
class ChatController extends AutoDisposeNotifier<ChatState> {
  static const pageSize = 50;

  /// Bir yoklamada en çok bu kadar sayfa (uzun bir kopukluktan sonra).
  static const _maxPollPages = 5;

  bool _disposed = false;
  bool _polling = false;
  bool _visible = false;

  /// Açılış (önbellek + ilk sayfa) ya da bir yenileme sürüyor: ekranın
  /// açılırken attığı ilk yoklama aynı isteği ikinci kez atmasın.
  bool _starting = true;
  bool _refreshing = false;
  int _markedSeq = 0;
  int _refreshGeneration = 0;
  String? _serverTime;

  /// Yoklamanın imleci: sunucudan sayfa olarak alınan en büyük numara.
  /// Listenin en büyük numarası DEĞİL -- kendi gönderdiğimiz mesaj (ör. 42)
  /// listeye yanıtından girer; ondan hemen önce başkasının yazdığı 41 henüz
  /// yoklanmamışken "after=42" onu kalıcı olarak atlardı.
  int _cursor = 0;

  ChatRepository get _repo => ref.read(chatRepositoryProvider);
  User? get _user => ref.read(authControllerProvider).valueOrNull;

  @override
  ChatState build() {
    ref.onDispose(() => _disposed = true);
    scheduleMicrotask(_start);
    return const ChatState();
  }

  Future<void> _start() async {
    try {
      // Oturum henüz yükleniyorsa (bildirime dokunup soğuk açılış) beklenir:
      // önbellek kişiye özeldir.
      User? user;
      try {
        user = await ref.read(authControllerProvider.future);
      } catch (_) {}
      if (_disposed) return;
      if (user != null) {
        final snap = await ref.read(chatCacheProvider).read(user.id);
        if (_disposed) return;
        if (snap != null && snap.organizationId == (user.organizationId ?? '') && !state.loadedFromServer) {
          state = state.copyWith(
            messages: snap.messages,
            muted: snap.muted,
            canModerate: snap.canModerate,
            lastReadSeq: snap.lastReadSeq,
            hasMoreOlder: snap.hasMoreOlder,
            initialLoading: false,
          );
        }
      }
      await refresh();
    } finally {
      _starting = false;
    }
  }

  /// En yeni sayfa (açılış, hata ekranındaki "Tekrar Dene", bağlantı dönünce).
  Future<void> refresh() async {
    final generation = ++_refreshGeneration;
    _refreshing = true;
    try {
      final page = await _repo.list(limit: pageSize);
      if (_disposed || generation != _refreshGeneration) return;
      _serverTime = page.serverTime ?? _serverTime;
      _cursor = page.messages.isEmpty ? 0 : page.messages.first.seq;
      final first = !state.loadedFromServer;
      state = state.copyWith(
        messages: page.messages,
        hasMoreOlder: page.hasMore,
        muted: page.muted,
        canModerate: page.canModerate,
        lastReadSeq: page.lastReadSeq,
        initialLoading: false,
        loadedFromServer: true,
        loadError: null,
        offline: false,
        firstUnreadSeq: first ? _firstUnread(page.messages, page.lastReadSeq) : state.firstUnreadSeq,
      );
      _saveCache();
      unawaited(markReadIfNeeded());
    } catch (e) {
      if (_disposed || generation != _refreshGeneration) return;
      state = state.copyWith(initialLoading: false, loadError: e, offline: isChatConnectivityError(e));
    } finally {
      if (generation == _refreshGeneration) _refreshing = false;
    }
  }

  static int? _firstUnread(List<ChatMessage> messages, int lastReadSeq) {
    int? first;
    for (final m in messages) {
      if (!m.isOwn && !m.deleted && m.seq > lastReadSeq) first = m.seq; // azalan sırada: sonuncusu en eski
    }
    return first;
  }

  /// Yeni mesajlar ve bu arada silinenler. Sunucudan hiç sayfa gelmediyse
  /// (açılışta bağlantı yoktu) en yeni sayfayı yeniden dener.
  Future<void> poll() async {
    if (_polling || _disposed || _starting || _refreshing) return;
    if (!state.loadedFromServer) {
      _polling = true;
      try {
        await refresh();
      } finally {
        _polling = false;
      }
      return;
    }
    _polling = true;
    try {
      String? since = _serverTime;
      for (var i = 0; i < _maxPollPages; i++) {
        final page = await _repo.list(after: _cursor, changedSince: since, limit: pageSize);
        if (_disposed) return;
        _serverTime = page.serverTime ?? _serverTime;
        if (page.messages.isNotEmpty) _cursor = max(_cursor, page.messages.first.seq);
        _merge(page.messages, updated: page.updated);
        state = state.copyWith(muted: page.muted, canModerate: page.canModerate, loadError: null, offline: false);
        if (!page.hasMore || page.messages.isEmpty) break;
        since = null; // silinenler ilk sayfada geldi
      }
      unawaited(markReadIfNeeded());
    } catch (e) {
      if (!_disposed) state = state.copyWith(loadError: e, offline: isChatConnectivityError(e));
    } finally {
      _polling = false;
    }
  }

  /// Yukarı kaydırınca daha eski sayfa.
  Future<void> loadOlder() async {
    if (_disposed || state.loadingOlder || !state.hasMoreOlder || state.messages.isEmpty) return;
    state = state.copyWith(loadingOlder: true);
    try {
      final page = await _repo.list(before: state.minSeq, limit: pageSize);
      if (_disposed) return;
      _merge(page.messages);
      state = state.copyWith(hasMoreOlder: page.hasMore, loadingOlder: false);
    } catch (e) {
      if (!_disposed) state = state.copyWith(loadingOlder: false, loadError: e, offline: isChatConnectivityError(e));
    }
  }

  /// Gelen mesajları (kimliğe göre tekilleştirerek) ve değişenleri (silinen)
  /// listeye işler; liste numaraya göre azalan kalır.
  void _merge(List<ChatMessage> incoming, {List<ChatMessage> updated = const []}) {
    if (incoming.isEmpty && updated.isEmpty) return;
    final byId = {for (final m in state.messages) m.id: m};
    var changed = false;
    for (final m in incoming) {
      changed |= byId[m.id]?.deleted != m.deleted || !byId.containsKey(m.id);
      byId[m.id] = m;
    }
    for (final m in updated) {
      if (byId.containsKey(m.id)) {
        changed |= byId[m.id]!.deleted != m.deleted;
        byId[m.id] = m;
        if (m.deleted) unawaited(ref.read(chatCacheProvider).removePhoto(m.id));
      }
    }
    if (!changed) return;
    final list = byId.values.toList()..sort((a, b) => b.seq.compareTo(a.seq));
    state = state.copyWith(messages: list);
    _saveCache();
  }

  // ---------- Gönderme ----------

  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _disposed) return;
    final p = PendingChatMessage(clientId: newChatClientId(), text: trimmed, createdAt: clock.now().toUtc());
    state = state.copyWith(pending: [...state.pending, p]);
    await _deliver(p);
  }

  /// Seçilen fotoğrafı gönderir. 25 MB'ı aşan dosya hiç gönderilmez (hata
  /// mesajı döner); seçici zaten küçültür.
  Future<String?> sendPhoto(PickedDeviceFile file) async {
    if (_disposed) return null;
    final size = file.size ?? await _fileLength(file.path);
    if (size != null && size > AppConfig.maxUploadBytes) return "Fotoğraf 25 MB'tan büyük olamaz.";
    final p = PendingChatMessage(
      clientId: newChatClientId(),
      text: '',
      photoPath: file.path,
      photoName: file.name,
      createdAt: clock.now().toUtc(),
    );
    state = state.copyWith(pending: [...state.pending, p]);
    unawaited(_deliver(p));
    return null;
  }

  static Future<int?> _fileLength(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return null;
    }
  }

  /// Gönderilemeyen mesajı aynı client_id ile yeniden gönderir.
  Future<void> retry(String clientId) async {
    final p = state.pending.where((x) => x.clientId == clientId).firstOrNull;
    if (p == null || p.status == ChatSendStatus.sending) return;
    await _deliver(p);
  }

  /// Gönderilemeyen mesajdan vazgeç.
  void discard(String clientId) {
    state = state.copyWith(pending: [for (final x in state.pending) if (x.clientId != clientId) x]);
  }

  Future<void> _deliver(PendingChatMessage p) async {
    _updatePending(p.clientId, (x) => x.copyWith(status: ChatSendStatus.sending, clearError: true));
    try {
      final msg = p.isPhoto
          ? await _repo.sendPhoto(
              filePath: p.photoPath!,
              fileName: p.photoName ?? 'foto.jpg',
              clientId: p.clientId,
              text: p.text,
              onSendProgress: (sent, total) {
                if (total > 0) _updatePending(p.clientId, (x) => x.copyWith(progress: sent / total));
              },
            )
          : await _repo.send(text: p.text, clientId: p.clientId);
      if (_disposed) return;
      state = state.copyWith(
        pending: [for (final x in state.pending) if (x.clientId != p.clientId) x],
        // Yazan kendi mesajına kadar okumuş sayılır (sunucu da öyle yazar).
        lastReadSeq: max(state.lastReadSeq, msg.seq),
        offline: false,
      );
      _markedSeq = max(_markedSeq, msg.seq);
      _merge([msg]);
    } catch (e) {
      if (_disposed) return;
      _updatePending(p.clientId, (x) => x.copyWith(status: ChatSendStatus.failed, error: _sendErrorText(e)));
    }
  }

  static String _sendErrorText(Object e) {
    if (isChatConnectivityError(e)) return 'Bağlantı yok';
    if (e is ApiException) return e.message;
    return 'Gönderilemedi';
  }

  void _updatePending(String clientId, PendingChatMessage Function(PendingChatMessage) update) {
    if (_disposed) return;
    state = state.copyWith(pending: [for (final x in state.pending) x.clientId == clientId ? update(x) : x]);
  }

  // ---------- Silme, sessize alma, okundu ----------

  /// Hata çağırana fırlatılır (ekran gösterir).
  Future<void> delete(String messageId) async {
    final msg = await _repo.delete(messageId);
    if (_disposed) return;
    _merge(const [], updated: [msg]);
  }

  /// Hata çağırana fırlatılır.
  Future<void> setMuted(bool muted) async {
    final st = await _repo.setMuted(muted);
    if (_disposed) return;
    state = state.copyWith(muted: st.muted);
    _saveCache();
  }

  /// Ekran önde mi (uygulama arka plandayken okundu sayılmaz).
  void setVisible(bool visible) {
    _visible = visible;
    if (visible) unawaited(markReadIfNeeded());
  }

  /// Ekran öndeyken: görülen en yeni mesaja kadar okundu. Okunmamış
  /// (başkasının) mesaj yoksa istek atılmaz.
  Future<void> markReadIfNeeded() async {
    if (!_visible || _disposed || !state.loadedFromServer) return;
    final top = state.maxSeq;
    if (top <= _markedSeq) return;
    final hasUnread = state.messages.any((m) => !m.isOwn && !m.deleted && m.seq > state.lastReadSeq);
    final previous = _markedSeq;
    _markedSeq = top;
    if (!hasUnread) return;
    try {
      final st = await _repo.markRead(top);
      if (_disposed) return;
      // lastReadSeq artışını ekran dinler, rozet ve zili o tazeler (sunucu
      // Firma Grubu bildirimini de kapattı). Burada ref.invalidate
      // yapılmaz: hata ayıklama derlemesinde bir sağlayıcının içinden
      // invalidate hedefi kurar -- kimse izlemezken zil listesi inerdi.
      state = state.copyWith(lastReadSeq: max(state.lastReadSeq, st.lastReadSeq), muted: st.muted);
      _saveCache();
    } catch (_) {
      // Bir sonraki yoklamada yeniden denenir.
      if (!_disposed) _markedSeq = previous;
    }
  }

  void _saveCache() {
    final user = _user;
    if (user == null || !state.loadedFromServer) return;
    unawaited(ref.read(chatCacheProvider).write(
          user.id,
          ChatSnapshot(
            organizationId: user.organizationId ?? '',
            messages: state.messages,
            muted: state.muted,
            canModerate: state.canModerate,
            lastReadSeq: state.lastReadSeq,
            hasMoreOlder: state.hasMoreOlder,
          ),
        ));
  }
}

final chatControllerProvider = AutoDisposeNotifierProvider<ChatController, ChatState>(ChatController.new);
