import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/notifications_providers.dart';
import '../domain/notification.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pageAsync = ref.watch(notificationsListProvider);
    final hasUnread = pageAsync.maybeWhen(
      data: (p) => p.notifications.any((n) => n.isUnread),
      orElse: () => false,
    );

    Future<void> markAllRead() async {
      await ref.read(notificationsRepositoryProvider).markAllRead();
      ref.invalidate(notificationsListProvider);
      ref.invalidate(unreadNotificationCountProvider);
    }

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
              icon: const Icon(Icons.done_all),
              tooltip: 'Tümünü okundu işaretle',
              onPressed: markAllRead,
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(notificationsListProvider),
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
                  onTap: () async {
                    if (notification.isUnread) {
                      await ref
                          .read(notificationsRepositoryProvider)
                          .markRead(notification.id);
                      ref.invalidate(notificationsListProvider);
                      ref.invalidate(unreadNotificationCountProvider);
                    }
                    if (notification.actionTarget.isNotEmpty &&
                        context.mounted) {
                      context.push(notification.actionTarget);
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification, required this.onTap});

  final AppNotification notification;
  final VoidCallback onTap;

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
                  Text(
                    notification.body,
                    style: AppTypography.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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
