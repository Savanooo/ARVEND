import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/notifications_providers.dart';
import '../domain/notification.dart';

/// Bildirimin hedefi bu listenin kendisi (ör. duyurular) -- dokununca
/// listenin ikinci bir kopyası açılmaz, metin yerinde açılır.
const kNotificationsRoute = '/diger/bildirimler';

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  final _expanded = <String>{};
  bool _markingAll = false;
  bool _loadingMore = false;

  void _showError(Object e) {
    if (!mounted) return;
    final message = e is ApiException ? e.message : 'Beklenmeyen bir hata oluştu.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _refreshBell() {
    ref.invalidate(notificationsListProvider);
    ref.invalidate(unreadNotificationCountProvider);
  }

  Future<void> _markAllRead() async {
    setState(() => _markingAll = true);
    try {
      await ref.read(notificationsRepositoryProvider).markAllRead();
      _refreshBell();
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _markingAll = false);
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      await ref.read(notificationsListProvider.notifier).loadMore();
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  bool _opensThisList(String target) {
    if (target.isEmpty || target == kNotificationsRoute) return true;
    final router = GoRouter.maybeOf(context);
    return router != null && router.routerDelegate.currentConfiguration.uri.path == target;
  }

  Future<void> _onTap(AppNotification notification) async {
    if (notification.isUnread) {
      try {
        await ref.read(notificationsRepositoryProvider).markRead(notification.id);
        _refreshBell();
      } catch (e) {
        // Okundu işaretlenemese de bildirim açılır; sebep gösterilir.
        _showError(e);
      }
    }
    if (!mounted) return;
    final target = notification.actionTarget;
    if (_opensThisList(target)) {
      // Duyuru vb.: gidilecek ayrı ekran yok -- tam metin yerinde açılır.
      setState(() => _expanded.contains(notification.id)
          ? _expanded.remove(notification.id)
          : _expanded.add(notification.id));
      return;
    }
    context.push(target);
  }

  @override
  Widget build(BuildContext context) {
    final pageAsync = ref.watch(notificationsListProvider);
    // Liste sayfalı: okunmamış bildirim ilk sayfada olmasa da "Tümünü
    // okundu" görünsün diye sunucunun sayacına bakılır.
    final unreadCount = ref.watch(unreadNotificationCountProvider).valueOrNull ?? 0;
    final hasUnread = unreadCount > 0 ||
        pageAsync.maybeWhen(
          data: (p) => p.notifications.any((n) => n.isUnread),
          orElse: () => false,
        );

    return Scaffold(
      appBar: buildAppBar(
        'Bildirimler',
        actions: [
          // Sahada istendi: "bildirim menüsünde öneri yeri olsun".
          IconButton(
            icon: const Icon(Icons.lightbulb_outline),
            tooltip: 'Öneri gönder',
            onPressed: () => context.push('/diger/oneri'),
          ),
          if (hasUnread)
            IconButton(
              icon: _markingAll
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.done_all),
              tooltip: 'Tümünü okundu işaretle',
              onPressed: _markingAll ? null : _markAllRead,
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => _refreshBell(),
        child: AsyncStateView(
          value: pageAsync,
          onRetry: () async => ref.invalidate(notificationsListProvider),
          isEmpty: (p) => p.notifications.isEmpty,
          emptyBuilder: (_) => const EmptyStateView(
            message: 'Bildirim yok.',
            icon: Icons.notifications_none_outlined,
          ),
          data: (context, page) => ListView(
            padding: kScreenPadding,
            children: [
              for (final notification in page.notifications)
                _NotificationTile(
                  notification: notification,
                  expandable: _opensThisList(notification.actionTarget),
                  expanded: _expanded.contains(notification.id),
                  onTap: () => _onTap(notification),
                ),
              if (page.hasMore)
                Center(
                  child: _loadingMore
                      ? const Padding(padding: EdgeInsets.all(AppSpacing.md), child: LoadingState())
                      : TextButton(
                          onPressed: _loadMore,
                          child: Text('Daha fazla göster (${page.notifications.length} / ${page.total})'),
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({
    required this.notification,
    required this.onTap,
    this.expandable = false,
    this.expanded = false,
  });

  final AppNotification notification;
  final VoidCallback onTap;

  /// Gidilecek ayrı ekran yok (duyuru): dokununca tam metin açılır/kapanır.
  final bool expandable;
  final bool expanded;

  IconData get _icon => switch (notification.entityType) {
    'task' => Icons.checklist_outlined,
    'offer' => Icons.description_outlined,
    'subcontract' => Icons.handshake_outlined,
    'subcontract_change_order' => Icons.rule_folder_outlined,
    'progress_claim' => Icons.receipt_long_outlined,
    'purchase_request' => Icons.shopping_cart_outlined,
    'rfq' => Icons.request_quote_outlined,
    'purchase_order' => Icons.local_shipping_outlined,
    'announcement' => Icons.campaign_outlined,
    'schedule_item' => Icons.event_note_outlined,
    'project_photo' => Icons.photo_camera_outlined,
    'project_file' => Icons.attach_file,
    _ => Icons.notifications_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final unread = notification.isUnread;
    final timestamp = Formatters.dateTime(notification.createdAt);
    return AppCard(
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      color: unread ? AppColors.gold.withValues(alpha: 0.06) : null,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: (unread ? AppColors.gold : AppColors.textMuted).withValues(
                alpha: 0.12,
              ),
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Icon(
              _icon,
              size: 18,
              color: unread ? AppColors.gold : AppColors.textMuted,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notification.title,
                  style: AppTypography.cardTitle.copyWith(
                    fontWeight: unread ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
                if (notification.body.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      // "Tamamını oku" yalnızca metin gerçekten 2 satıra
                      // sığmıyorsa (ya da zaten açıksa) gösterilir.
                      final painter = TextPainter(
                        text: TextSpan(text: notification.body, style: AppTypography.body),
                        maxLines: 2,
                        textDirection: Directionality.of(context),
                        textScaler: MediaQuery.textScalerOf(context),
                      )..layout(maxWidth: constraints.maxWidth);
                      final showToggle = expandable && (expanded || painter.didExceedMaxLines);
                      painter.dispose();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            notification.body,
                            style: AppTypography.body,
                            maxLines: expanded ? null : 2,
                            overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                          ),
                          if (showToggle)
                            Text(
                              expanded ? 'Daha az' : 'Tamamını oku',
                              style: AppTypography.helper.copyWith(color: AppColors.info, fontWeight: FontWeight.w600),
                            ),
                        ],
                      );
                    },
                  ),
                ],
                const SizedBox(height: 4),
                Text(timestamp, style: AppTypography.helper),
              ],
            ),
          ),
          if (unread) ...[
            const SizedBox(width: AppSpacing.sm),
            const Padding(
              padding: EdgeInsets.only(top: AppSpacing.xs),
              child: SizedBox(
                width: 8,
                height: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: AppColors.gold,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
