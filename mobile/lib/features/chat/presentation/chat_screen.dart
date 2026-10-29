import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/errors/device_errors.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_sheet.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../notifications/data/notifications_providers.dart';
import '../data/chat_providers.dart';
import '../domain/chat_format.dart';
import '../domain/chat_message.dart';
import 'chat_photo_viewer.dart';

/// Firma Grubu (backend migration 0077): firmanın tek grup sohbeti.
/// Mesajlar alttan yukarı (en yeni altta), kendi mesajın sağda, gün
/// ayraçları; fotoğraf küçük resim (dokununca tam ekran). Ekran öndeyken 5
/// sn'de bir yoklar ve görülen mesajları okundu sayar; uygulama arka plana
/// geçince durur, öne gelince hemen yoklar. Bağlantı yoksa son kaydedilen
/// mesajlar "Bağlantı yok" bandıyla kalır; gönderilemeyen mesaj kuyruğa
/// girmez, balonunda "Tekrar dene" olur.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  /// Ekran açıkken yoklama aralığı.
  static const pollInterval = Duration(seconds: 5);

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  late final AppLifecycleListener _lifecycle;
  Timer? _timer;

  /// Uygulama önde mi.
  bool _appResumed = true;

  /// Sekme (alt menü dalı) önde mi: kabuk başka sekmeye geçince bu ekranı
  /// ağaçta tutar ama TickerMode'u kapatır. Görünmeyen sohbet yoklamasın ve
  /// gelen mesajları "okundu" saymasın -- rozet doğru kalsın.
  bool _branchActive = true;

  /// Son uygulanan durum (null = henüz uygulanmadı).
  bool? _foreground;

  ChatController get _chat => ref.read(chatControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    _scroll.addListener(_onScroll);
    final s = WidgetsBinding.instance.lifecycleState;
    _appResumed = s == null || s == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _branchActive = TickerMode.valuesOf(context).enabled;
    // Kurulum sırasında sağlayıcı durumu değiştirilmez: bir sonraki karede.
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyVisibility());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle.dispose();
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  void _onLifecycle(AppLifecycleState s) {
    _appResumed = s == AppLifecycleState.resumed;
    _applyVisibility();
  }

  /// Görünürken yoklar ve okundu sayar; görünmezken ikisi de durur.
  void _applyVisibility() {
    if (!mounted) return;
    final foreground = _appResumed && _branchActive;
    if (foreground == _foreground) return;
    _foreground = foreground;
    _chat.setVisible(foreground);
    _timer?.cancel();
    _timer = null;
    if (!foreground) return;
    // Görünür olunca beklemeden (bildirime dokunup dönülmüş olabilir).
    unawaited(_chat.poll());
    _timer = Timer.periodic(ChatScreen.pollInterval, (_) => unawaited(_chat.poll()));
  }

  void _onScroll() {
    // Ters liste: en eski mesajlar kaydırmanın sonunda.
    final p = _scroll.position;
    if (p.pixels >= p.maxScrollExtent - 400) unawaited(_chat.loadOlder());
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await _chat.send(text);
  }

  Future<void> _pickPhoto() async {
    final source = await showAppSheet<ImageSource>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Fotoğraf çek'),
              onTap: () => Navigator.of(context).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Galeriden seç'),
              onTap: () => Navigator.of(context).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    try {
      final file = await ref.read(chatPhotoPickerProvider).pick(source);
      if (file == null || !mounted) return;
      final problem = await _chat.sendPhoto(file);
      if (problem != null && mounted) _toast(problem);
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (e, st) {
      if (!mounted) return;
      showDeviceIssue(context, ref, e, st, source == ImageSource.camera ? DeviceAction.camera : DeviceAction.gallery,
          where: 'Firma Grubu fotoğraf');
    }
  }

  Future<void> _toggleMute(bool muted) async {
    try {
      await _chat.setMuted(!muted);
      if (mounted) _toast(muted ? 'Firma Grubu bildirimleri açıldı.' : 'Firma Grubu bildirimleri sessize alındı.');
    } catch (e) {
      if (mounted) _toast(e.toString());
    }
  }

  Future<void> _onMessageLongPress(ChatMessage m) async {
    if (m.deleted || (m.text.isEmpty && !m.canDelete)) return;
    final action = await showAppSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (m.text.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('Metni kopyala'),
                onTap: () => Navigator.of(context).pop('copy'),
              ),
            if (m.canDelete)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: AppColors.danger),
                title: const Text('Sil', style: TextStyle(color: AppColors.danger)),
                onTap: () => Navigator.of(context).pop('delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
        if (mounted) _toast('Metin kopyalandı.');
      case 'delete':
        await _confirmDelete(m);
    }
  }

  Future<void> _confirmDelete(ChatMessage m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mesaj silinsin mi?'),
        content: Text(m.isOwn
            ? 'Mesaj gruptaki herkes için "Mesaj silindi" olarak görünecek.'
            : '${m.authorName} kişisinin mesajı gruptaki herkes için "Mesaj silindi" olarak görünecek.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _chat.delete(m.id);
    } catch (e) {
      if (mounted) _toast(e.toString());
    }
  }

  Future<void> _onPendingTap(PendingChatMessage p) async {
    if (p.status != ChatSendStatus.failed) return;
    final action = await showAppSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Tekrar dene'),
              onTap: () => Navigator.of(context).pop('retry'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.danger),
              title: const Text('Vazgeç', style: TextStyle(color: AppColors.danger)),
              subtitle: const Text('Mesaj gönderilmeden silinir'),
              onTap: () => Navigator.of(context).pop('discard'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'retry':
        await _chat.retry(p.clientId);
      case 'discard':
        _chat.discard(p.clientId);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(chatPushTickProvider, (_, _) => unawaited(_chat.poll()));
    // Okundu ilerledi: Ana Sayfa/Diğer rozeti ve zil (sunucu Firma Grubu
    // bildirimini de kapattı) dönüşte güncel olsun.
    ref.listen<int>(chatControllerProvider.select((s) => s.lastReadSeq), (prev, next) {
      if (prev == null || next <= prev) return;
      ref.invalidate(chatUnreadCountProvider);
      ref.invalidate(unreadNotificationCountProvider);
      ref.invalidate(notificationsListProvider);
    });
    final state = ref.watch(chatControllerProvider);

    final Widget content;
    if (state.messages.isEmpty && state.pending.isEmpty) {
      if (state.initialLoading) {
        content = const LoadingState();
      } else if (!state.loadedFromServer && state.loadError != null) {
        content = ErrorState(error: state.loadError!, onRetry: _chat.refresh);
      } else {
        content = const _EmptyChat();
      }
    } else {
      content = _MessageList(
        state: state,
        controller: _scroll,
        onLongPress: _onMessageLongPress,
        onPendingTap: _onPendingTap,
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Flexible(child: Text('Firma Grubu', maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (state.muted) ...[
              const SizedBox(width: AppSpacing.sm),
              const Tooltip(
                message: 'Bildirimler sessizde',
                child: Icon(Icons.notifications_off_outlined, size: 18, color: AppColors.textMuted),
              ),
            ],
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Seçenekler',
            onSelected: (_) => _toggleMute(state.muted),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'mute',
                child: Text(state.muted ? 'Bildirimleri aç' : 'Bildirimleri sessize al'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (state.offline || (state.loadError != null && state.messages.isNotEmpty))
            _StatusBanner(offline: state.offline),
          Expanded(child: content),
          _Composer(controller: _input, onSend: _send, onAttach: _pickPhoto),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.offline});

  final bool offline;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.warning.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
      child: Row(
        children: [
          Icon(offline ? Icons.wifi_off : Icons.sync_problem, size: 18, color: AppColors.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              offline
                  ? 'Bağlantı yok. Son kaydedilen mesajlar gösteriliyor.'
                  : 'Mesajlar yenilenemedi; birazdan tekrar denenecek.',
              style: AppTypography.helper.copyWith(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 44, color: AppColors.textMuted),
            SizedBox(height: AppSpacing.md),
            Text('Henüz mesaj yok', style: AppTypography.cardTitle, textAlign: TextAlign.center),
            SizedBox(height: AppSpacing.xs),
            Text(
              'Firmadaki herkesin göreceği ilk mesajı yaz.',
              style: AppTypography.metadata,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- Liste ----------

/// Listenin bir satırı (eskiden yeniye kurulur, ters listede alttan çizilir).
sealed class _Entry {
  const _Entry();
  Key get key;
}

class _DayEntry extends _Entry {
  const _DayEntry(this.label, this.day);
  final String label;
  final DateTime day;
  @override
  Key get key => ValueKey('gun-${day.toIso8601String()}');
}

class _UnreadEntry extends _Entry {
  const _UnreadEntry();
  @override
  Key get key => const ValueKey('okunmamis');
}

class _MessageEntry extends _Entry {
  const _MessageEntry(this.message, {required this.showAuthor});
  final ChatMessage message;
  final bool showAuthor;
  @override
  Key get key => ValueKey('m-${message.id}');
}

class _PendingEntry extends _Entry {
  const _PendingEntry(this.pending);
  final PendingChatMessage pending;
  @override
  Key get key => ValueKey('p-${pending.clientId}');
}

List<_Entry> _buildEntries(ChatState state, DateTime now) {
  final out = <_Entry>[];
  DateTime? lastDay;
  String? lastAuthor;
  void day(DateTime? d) {
    if (d == null || d == lastDay) return;
    out.add(_DayEntry(chatDayLabel(d, now), d));
    lastDay = d;
    lastAuthor = null;
  }

  for (final m in state.messages.reversed) {
    day(chatDay(m.createdAt));
    if (state.firstUnreadSeq == m.seq) {
      out.add(const _UnreadEntry());
      lastAuthor = null;
    }
    final author = m.isOwn ? '__ben__' : (m.authorId ?? m.authorName);
    out.add(_MessageEntry(m, showAuthor: !m.isOwn && author != lastAuthor));
    lastAuthor = author;
  }
  for (final p in state.pending) {
    day(chatDayOf(p.createdAt));
    out.add(_PendingEntry(p));
    lastAuthor = '__ben__';
  }
  return out;
}

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.state,
    required this.controller,
    required this.onLongPress,
    required this.onPendingTap,
  });

  final ChatState state;
  final ScrollController controller;
  final void Function(ChatMessage) onLongPress;
  final void Function(PendingChatMessage) onPendingTap;

  @override
  Widget build(BuildContext context) {
    final entries = _buildEntries(state, clock.now());
    final showLoader = state.loadingOlder;
    return ListView.builder(
      controller: controller,
      reverse: true,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      itemCount: entries.length + (showLoader ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= entries.length) {
          return const Padding(
            padding: EdgeInsets.all(AppSpacing.md),
            child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        final e = entries[entries.length - 1 - index];
        return KeyedSubtree(
          key: e.key,
          child: switch (e) {
            _DayEntry(:final label) => _DaySeparator(label: label),
            _UnreadEntry() => const _UnreadDivider(),
            _MessageEntry(:final message, :final showAuthor) => _MessageBubble(
                message: message,
                showAuthor: showAuthor,
                onLongPress: () => onLongPress(message),
              ),
            _PendingEntry(:final pending) => _PendingBubble(pending: pending, onTap: () => onPendingTap(pending)),
          },
        );
      },
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            color: AppColors.border.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(AppRadius.badge * 2),
          ),
          child: Text(label, style: AppTypography.helper.copyWith(color: AppColors.textPrimary)),
        ),
      ),
    );
  }
}

class _UnreadDivider extends StatelessWidget {
  const _UnreadDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          const Expanded(child: Divider(color: AppColors.gold)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Text(
              'Okunmamış mesajlar',
              style: AppTypography.helper.copyWith(color: AppColors.gold, fontWeight: FontWeight.w600),
            ),
          ),
          const Expanded(child: Divider(color: AppColors.gold)),
        ],
      ),
    );
  }
}

/// Yazar adının rengi: kişiye göre sabit, okunaklı koyu tonlar.
const _authorColors = <Color>[
  Color(0xFF1D4ED8),
  Color(0xFF047857),
  Color(0xFFB45309),
  Color(0xFF7C3AED),
  Color(0xFFBE123C),
  Color(0xFF0E7490),
];

Color _authorColor(String key) {
  var h = 0;
  for (final c in key.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return _authorColors[h % _authorColors.length];
}

/// Balon kabuğu: kendi mesajı sağda (altın tonu), başkasınınki solda
/// (beyaz, çerçeveli). Genişlik ekranın %78'i -- 320 pt'lik telefonda da
/// karşı taraf görünür kalır.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.own, required this.child, this.onTap, this.onLongPress, this.topGap = false});

  final bool own;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool topGap;

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width * 0.78;
    const r = Radius.circular(AppRadius.card);
    const tight = Radius.circular(4);
    final radius = BorderRadius.only(
      topLeft: r,
      topRight: r,
      bottomLeft: own ? r : tight,
      bottomRight: own ? tight : r,
    );
    return Padding(
      padding: EdgeInsets.only(top: topGap ? AppSpacing.sm : 2, bottom: 2),
      child: Align(
        alignment: own ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Material(
            color: own ? AppColors.gold.withValues(alpha: 0.16) : AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: own ? BorderSide.none : const BorderSide(color: AppColors.border),
            ),
            child: InkWell(
              borderRadius: radius,
              onTap: onTap,
              onLongPress: onLongPress,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs + 2),
                // İçerik kadar geniş: sağa yaslı saat satırı balonu tam
                // genişliğe yaymasın ("Tamam" yazan balon dar kalsın).
                child: IntrinsicWidth(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.showAuthor, required this.onLongPress});

  final ChatMessage message;
  final bool showAuthor;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final time = chatTime(m.createdAt);
    return Semantics(
      label: '${m.isOwn ? 'Sen' : m.authorName}, $time',
      child: _Bubble(
        own: m.isOwn,
        topGap: showAuthor,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showAuthor)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  m.authorName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.helper.copyWith(
                    fontWeight: FontWeight.w700,
                    color: _authorColor(m.authorId ?? m.authorName),
                  ),
                ),
              ),
            if (m.deleted)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.block, size: 16, color: AppColors.textMuted),
                  const SizedBox(width: AppSpacing.xs),
                  Flexible(
                    child: Text(
                      'Mesaj silindi',
                      style: AppTypography.body.copyWith(color: AppColors.textMuted, fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
              )
            else ...[
              if (m.photo != null)
                Padding(
                  padding: EdgeInsets.only(bottom: m.text.isEmpty ? 0 : AppSpacing.xs),
                  child: _PhotoThumb(
                    messageId: m.id,
                    onTap: () => ChatPhotoViewer.open(
                      context,
                      messageId: m.id,
                      title: m.isOwn ? 'Sen' : m.authorName,
                      subtitle: time,
                    ),
                    onLongPress: onLongPress,
                  ),
                ),
              if (m.text.isNotEmpty) Text(m.text, style: AppTypography.body),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(time, style: AppTypography.helper.copyWith(fontSize: 11)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Küçük resim: sabit kutu (yüklenince balon zıplamasın), kırpılarak
/// doldurulur; bayt ekran genişliğinde çözülür (bellekte tam çözünürlük
/// tutulmaz).
class _PhotoThumb extends ConsumerWidget {
  const _PhotoThumb({required this.messageId, required this.onTap, required this.onLongPress});

  final String messageId;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(chatPhotoBytesProvider(messageId));
    final width = math.min(240.0, MediaQuery.sizeOf(context).width * 0.78 - AppSpacing.md * 2);
    final height = width * 0.75;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Semantics(
      button: true,
      label: 'Fotoğraf, büyütmek için dokun',
      child: GestureDetector(
        onTap: bytes.hasValue ? onTap : () => ref.invalidate(chatPhotoBytesProvider(messageId)),
        onLongPress: onLongPress,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.control),
          child: SizedBox(
            width: width,
            height: height,
            child: bytes.when(
              data: (b) => Image.memory(
                b,
                fit: BoxFit.cover,
                cacheWidth: (width * dpr).round(),
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const _PhotoPlaceholder(icon: Icons.broken_image_outlined),
              ),
              loading: () => const _PhotoPlaceholder(loading: true),
              error: (_, _) => const _PhotoPlaceholder(icon: Icons.refresh, label: 'Yüklenemedi, dokun'),
            ),
          ),
        ),
      ),
    );
  }
}

class _PhotoPlaceholder extends StatelessWidget {
  const _PhotoPlaceholder({this.icon = Icons.image_outlined, this.label, this.loading = false});

  final IconData icon;
  final String? label;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.border,
      child: Center(
        child: loading
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: AppColors.textMuted),
                  if (label != null) Text(label!, style: AppTypography.helper),
                ],
              ),
      ),
    );
  }
}

class _PendingBubble extends StatelessWidget {
  const _PendingBubble({required this.pending, required this.onTap});

  final PendingChatMessage pending;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = pending;
    final failed = p.status == ChatSendStatus.failed;
    final width = math.min(240.0, MediaQuery.sizeOf(context).width * 0.78 - AppSpacing.md * 2);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final status = failed
        ? 'Gönderilemedi${p.error == null ? '' : ' (${p.error})'} · Tekrar dene'
        : p.isPhoto && p.progress != null
            ? 'Gönderiliyor… %${(p.progress! * 100).clamp(0, 100).round()}'
            : 'Gönderiliyor…';
    return _Bubble(
      own: true,
      onTap: failed ? onTap : null,
      onLongPress: failed ? onTap : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (p.isPhoto)
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.control),
              child: Opacity(
                opacity: failed ? 0.6 : 0.85,
                child: Image.file(
                  File(p.photoPath!),
                  width: width,
                  height: width * 0.75,
                  fit: BoxFit.cover,
                  cacheWidth: (width * dpr).round(),
                  errorBuilder: (_, _, _) => SizedBox(
                    width: width,
                    height: width * 0.75,
                    child: const _PhotoPlaceholder(),
                  ),
                ),
              ),
            ),
          if (p.text.isNotEmpty) Text(p.text, style: AppTypography.body),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    failed ? Icons.error_outline : Icons.schedule,
                    size: 14,
                    color: failed ? AppColors.danger : AppColors.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      status,
                      style: AppTypography.helper.copyWith(
                        fontSize: 11,
                        color: failed ? AppColors.danger : AppColors.textMuted,
                        fontWeight: failed ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Yazma alanı ----------

class _Composer extends StatelessWidget {
  const _Composer({required this.controller, required this.onSend, required this.onAttach});

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      child: Container(
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.border))),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.xs, AppSpacing.xs, AppSpacing.xs, AppSpacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Fotoğraf gönder',
                  icon: const Icon(Icons.add_a_photo_outlined),
                  onPressed: onAttach,
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 5,
                    maxLength: kChatMaxTextLength,
                    maxLengthEnforcement: MaxLengthEnforcement.enforced,
                    // Sınıra yaklaşınca sayaç görünür; normalde yer kaplamaz.
                    buildCounter: (context, {required currentLength, required isFocused, maxLength}) =>
                        currentLength > kChatMaxTextLength - 200
                            ? Text('$currentLength/$maxLength', style: AppTypography.helper)
                            : null,
                    keyboardType: TextInputType.multiline,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: 'Mesaj yaz',
                      isDense: true,
                      filled: true,
                      fillColor: AppColors.background,
                      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.card),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.card),
                        borderSide: const BorderSide(color: AppColors.border),
                      ),
                    ),
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) => IconButton(
                    tooltip: 'Gönder',
                    icon: const Icon(Icons.send),
                    color: AppColors.gold,
                    onPressed: value.text.trim().isEmpty ? null : onSend,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
