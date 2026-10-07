import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/notification.dart';
import 'notifications_repository.dart';

final notificationsRepositoryProvider =
    Provider<NotificationsRepository>((ref) => NotificationsRepository(ref.watch(apiClientProvider)));

/// Zil listesi: ilk sayfa açılışta, sonrakiler "Daha fazla göster" ile
/// (backend sayfa başına en çok 100 döner; eskiden yalnızca ilk 50 vardı).
class NotificationsListNotifier extends AutoDisposeAsyncNotifier<NotificationsPage> {
  static const pageSize = 50;

  int _page = 1;

  @override
  Future<NotificationsPage> build() {
    _page = 1;
    return ref.watch(notificationsRepositoryProvider).list(page: 1, limit: pageSize);
  }

  /// Sonraki sayfayı ekler; hata çağırana fırlatılır (ekran gösterir),
  /// eldeki liste korunur.
  Future<void> loadMore() async {
    final current = state.valueOrNull;
    if (current == null || !current.hasMore) return;
    final next = await ref.read(notificationsRepositoryProvider).list(page: _page + 1, limit: pageSize);
    // Bu arada yenilendiyse (invalidate) eski listeye ekleme.
    if (!identical(state.valueOrNull, current)) return;
    _page++;
    final seen = {for (final n in current.notifications) n.id};
    state = AsyncData(NotificationsPage(
      notifications: [...current.notifications, for (final n in next.notifications) if (seen.add(n.id)) n],
      total: next.total,
      // Boş sayfa: liste bu arada kısaldı, daha fazlası yok.
      reachedEnd: next.notifications.isEmpty,
    ));
  }
}

final notificationsListProvider =
    AsyncNotifierProvider.autoDispose<NotificationsListNotifier, NotificationsPage>(NotificationsListNotifier.new);

final unreadNotificationCountProvider = FutureProvider.autoDispose<int>(
  (ref) => ref.watch(notificationsRepositoryProvider).unreadCount(),
);
