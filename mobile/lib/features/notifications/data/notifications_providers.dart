import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/notification.dart';
import 'notifications_repository.dart';

final notificationsRepositoryProvider =
    Provider<NotificationsRepository>((ref) => NotificationsRepository(ref.watch(apiClientProvider)));

final notificationsListProvider = FutureProvider.autoDispose<NotificationsPage>(
  (ref) => ref.watch(notificationsRepositoryProvider).list(),
);

final unreadNotificationCountProvider = FutureProvider.autoDispose<int>(
  (ref) => ref.watch(notificationsRepositoryProvider).unreadCount(),
);
