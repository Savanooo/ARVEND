import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/features/notifications/data/notifications_providers.dart';
import 'package:arvend/features/notifications/data/notifications_repository.dart';
import 'package:arvend/features/notifications/domain/notification.dart';

import 'test_utils/fake_api_client.dart';

void main() {
  group('parsing', () {
    test('AppNotification.fromJson reads the exact backend field set', () {
      final n = AppNotification.fromJson(_notificationJson(id: 'n1'));
      expect(n.id, 'n1');
      expect(n.type, 'task_assigned');
      expect(n.title, 'Yeni görev atandı');
      expect(n.body, 'GRV-1');
      expect(n.entityType, 'task');
      expect(n.entityId, 'task-1');
      expect(n.projectId, 'proj-1');
      expect(n.actionTarget, '/projeler/proj-1/gorevler/task-1');
      expect(n.readAt, isNull);
      expect(n.createdAt, '2026-09-20T08:00:00Z');
    });

    test('read_at null -> isUnread true; read_at present -> isUnread false', () {
      final unread = AppNotification.fromJson(_notificationJson(id: 'n1'));
      expect(unread.isUnread, isTrue);

      final read = AppNotification.fromJson(_notificationJson(id: 'n2', readAt: '2026-09-20T09:00:00Z'));
      expect(read.isUnread, isFalse);
      expect(read.readAt, '2026-09-20T09:00:00Z');
    });

    test('missing entity_id/project_id and empty action_target default cleanly', () {
      final json = _notificationJson(id: 'n1')
        ..remove('entity_id')
        ..remove('project_id')
        ..remove('action_target');
      final n = AppNotification.fromJson(json);
      expect(n.entityId, isNull);
      expect(n.projectId, isNull);
      expect(n.actionTarget, '');
    });
  });

  group('list', () {
    test('list() unwraps notifications + total and sends page/limit as query params', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/notifications': [
          (
            status: 200,
            body: {
              'notifications': [_notificationJson(id: 'n1'), _notificationJson(id: 'n2', readAt: '2026-09-20T09:00:00Z')],
              'total': 2,
            },
          ),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = NotificationsRepository(client);

      final page = await repo.list();

      expect(page.total, 2);
      expect(page.notifications.map((n) => n.id), ['n1', 'n2']);
      expect(adapter.calls, ['/notifications']);
      expect(adapter.requestQueries.single['page'], 1);
      expect(adapter.requestQueries.single['limit'], 50);
    });

    test('unreadCount() returns the backend unread_count', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/notifications/unread-count': [(status: 200, body: {'unread_count': 3})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = NotificationsRepository(client);

      expect(await repo.unreadCount(), 3);
    });
  });

  group('mark read', () {
    test('markRead() POSTs to /notifications/{id}/read', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/notifications/n1/read': [(status: 200, body: {'ok': true})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = NotificationsRepository(client);

      await repo.markRead('n1');

      expect(adapter.calls, ['/notifications/n1/read']);
    });

    test('markAllRead() POSTs to /notifications/read-all', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/notifications/read-all': [(status: 200, body: {'ok': true})],
      });
      final client = await buildFakeApiClient(adapter);
      final repo = NotificationsRepository(client);

      await repo.markAllRead();

      expect(adapter.calls, ['/notifications/read-all']);
    });
  });

  group('providers / refresh after mutation', () {
    test('notificationsListProvider fetches through the repository', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/notifications': [
          (status: 200, body: {'notifications': [_notificationJson(id: 'n1')], 'total': 1}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final page = await container.read(notificationsListProvider.future);

      expect(page.notifications, hasLength(1));
      expect(page.notifications.single.id, 'n1');
    });

    test('invalidating notificationsListProvider triggers a fresh fetch (e.g. after mark-read)', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/notifications': [
          (
            status: 200,
            body: {'notifications': [_notificationJson(id: 'n1')], 'total': 1},
          ),
          (status: 200, body: {'notifications': <Map<String, dynamic>>[], 'total': 0}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      final before = await container.read(notificationsListProvider.future);
      expect(before.notifications, hasLength(1));

      container.invalidate(notificationsListProvider);
      final after = await container.read(notificationsListProvider.future);

      expect(after.notifications, isEmpty);
      expect(adapter.calls.where((p) => p == '/notifications').length, 2);
    });

    test('unreadNotificationCountProvider fetches through the repository and reflects invalidation', () async {
      final adapter = FakeHttpClientAdapter(script: {
        '/notifications/unread-count': [
          (status: 200, body: {'unread_count': 2}),
          (status: 200, body: {'unread_count': 0}),
        ],
      });
      final client = await buildFakeApiClient(adapter);
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(client)]);
      addTearDown(container.dispose);

      expect(await container.read(unreadNotificationCountProvider.future), 2);

      container.invalidate(unreadNotificationCountProvider);
      expect(await container.read(unreadNotificationCountProvider.future), 0);
    });
  });
}

Map<String, dynamic> _notificationJson({required String id, String? readAt}) => {
      'id': id,
      'type': 'task_assigned',
      'title': 'Yeni görev atandı',
      'body': 'GRV-1',
      'entity_type': 'task',
      'entity_id': 'task-1',
      'project_id': 'proj-1',
      'action_target': '/projeler/proj-1/gorevler/task-1',
      'read_at': readAt,
      'created_at': '2026-09-20T08:00:00Z',
    };
