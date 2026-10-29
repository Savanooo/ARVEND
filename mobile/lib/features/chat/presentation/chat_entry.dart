import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../data/chat_providers.dart';
import '../domain/chat_message.dart';

/// Ana Sayfa üst çubuğunda zilin yanındaki Firma Grubu girişi (okunmamış
/// rozetiyle). Grubu göremeyende (izin yok, taşeron) hiç çizilmez.
class ChatAppBarButton extends ConsumerWidget {
  const ChatAppBarButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed = ref.watch(authControllerProvider.select((s) => canUseChat(s.valueOrNull)));
    if (!allowed) return const SizedBox.shrink();
    final unread = ref.watch(chatUnreadCountProvider).valueOrNull ?? 0;
    return IconButton(
      tooltip: unread > 0 ? 'Firma Grubu, $unread okunmamış' : 'Firma Grubu',
      icon: Badge(
        label: Text(chatBadgeLabel(unread)),
        isLabelVisible: unread > 0,
        child: const Icon(Icons.forum_outlined),
      ),
      onPressed: () => context.push(kChatRoute),
    );
  }
}

/// Diğer menüsündeki satırın sağındaki okunmamış sayısı (yoksa boş).
class ChatUnreadPill extends ConsumerWidget {
  const ChatUnreadPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(chatUnreadCountProvider).valueOrNull ?? 0;
    if (unread <= 0) return const SizedBox.shrink();
    return Semantics(
      label: '$unread okunmamış',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: AppColors.danger, borderRadius: BorderRadius.circular(10)),
        child: Text(
          chatBadgeLabel(unread),
          style: AppTypography.helper.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
