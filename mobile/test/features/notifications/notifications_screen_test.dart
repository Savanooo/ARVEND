import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/features/notifications/presentation/notifications_screen.dart';

import '../../test_utils/fake_api_client.dart';

Map<String, dynamic> _n({
  String id = 'n1',
  String title = 'Görev atandı',
  String body = 'Detaylar için dokunun',
  String? readAt = '2026-09-20T11:00:00Z',
  String actionTarget = '/hedef',
  String entityType = 'task',
}) =>
    {
      'id': id,
      'type': 'task_assigned',
      'title': title,
      'body': body,
      'entity_type': entityType,
      'entity_id': 't1',
      'project_id': 'p1',
      'action_target': actionTarget,
      'read_at': readAt,
      'created_at': '2026-09-20T10:00:00Z',
    };

Future<GoRouter> _pump(WidgetTester tester, FakeHttpClientAdapter adapter) async {
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(const Size(400, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final router = GoRouter(
    initialLocation: kNotificationsRoute,
    routes: [
      GoRoute(path: kNotificationsRoute, builder: (c, s) => const NotificationsScreen()),
      GoRoute(path: '/hedef', builder: (c, s) => const Scaffold(body: Text('HEDEF EKRAN'))),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(client)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  testWidgets('okunmamışlar ilk sayfada olmasa da sayaç > 0 ise "Tümünü okundu" görünür', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/notifications': [
        (status: 200, body: {'notifications': [_n()], 'total': 120}),
        (status: 200, body: {'notifications': [_n()], 'total': 120}),
      ],
      '/notifications/unread-count': [
        (status: 200, body: {'unread_count': 7}),
        (status: 200, body: {'unread_count': 0}),
      ],
      '/notifications/read-all': [(status: 200, body: {'ok': true})],
    });
    await _pump(tester, adapter);

    final markAll = find.byTooltip('Tümünü okundu işaretle');
    expect(markAll, findsOneWidget);
    await tester.tap(markAll);
    await tester.pumpAndSettle();

    expect(adapter.calls, contains('/notifications/read-all'));
    expect(find.byTooltip('Tümünü okundu işaretle'), findsNothing);
  });

  testWidgets('"Tümünü okundu" başarısız olursa backend mesajı gösterilir', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/notifications': [
        (status: 200, body: {'notifications': [_n(readAt: null)], 'total': 1}),
      ],
      '/notifications/unread-count': [(status: 200, body: {'unread_count': 1})],
      '/notifications/read-all': [(status: 500, body: {'error': 'bildirimler güncellenemedi'})],
    });
    await _pump(tester, adapter);

    await tester.tap(find.byTooltip('Tümünü okundu işaretle'));
    await tester.pumpAndSettle();

    expect(find.text('bildirimler güncellenemedi'), findsOneWidget);
  });

  testWidgets('okundu işaretleme başarısız olursa sebep gösterilir, hedef yine açılır', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/notifications': [
        (status: 200, body: {'notifications': [_n(readAt: null)], 'total': 1}),
      ],
      '/notifications/unread-count': [(status: 200, body: {'unread_count': 1})],
      '/notifications/n1/read': [(status: 500, body: {'error': 'okundu işaretlenemedi'})],
    });
    await _pump(tester, adapter);

    await tester.tap(find.text('Görev atandı'));
    await tester.pumpAndSettle();

    expect(find.text('okundu işaretlenemedi'), findsOneWidget);
    expect(find.text('HEDEF EKRAN'), findsOneWidget);
  });

  testWidgets('duyuru (hedefi bu liste): ikinci liste açılmaz, tam metin yerinde açılır', (tester) async {
    final longBody = 'Yarın sabah 08:00 itibarıyla tüm şantiyelerde iş güvenliği denetimi yapılacaktır. ' * 4;
    final adapter = FakeHttpClientAdapter(script: {
      '/notifications': [
        (
          status: 200,
          body: {
            'notifications': [
              _n(title: 'Duyuru', body: longBody, actionTarget: kNotificationsRoute, entityType: 'announcement'),
            ],
            'total': 1,
          },
        ),
      ],
      '/notifications/unread-count': [(status: 200, body: {'unread_count': 0})],
    });
    final router = await _pump(tester, adapter);
    Text bodyText() => tester.widget<Text>(find.text(longBody));
    expect(bodyText().maxLines, 2);
    expect(find.text('Tamamını oku'), findsOneWidget);

    await tester.tap(find.text('Duyuru'));
    await tester.pumpAndSettle();

    expect(router.routerDelegate.currentConfiguration.matches.length, 1);
    expect(bodyText().maxLines, isNull);
    expect(find.text('Daha az'), findsOneWidget);
  });

  testWidgets('"Daha fazla göster" sonraki sayfayı ekler', (tester) async {
    final adapter = FakeHttpClientAdapter(script: {
      '/notifications': [
        (status: 200, body: {'notifications': [_n(id: 'n1', title: 'Birinci')], 'total': 2}),
        (status: 200, body: {'notifications': [_n(id: 'n2', title: 'İkinci')], 'total': 2}),
      ],
      '/notifications/unread-count': [(status: 200, body: {'unread_count': 0})],
    });
    await _pump(tester, adapter);
    expect(find.text('İkinci'), findsNothing);

    await tester.tap(find.text('Daha fazla göster (1 / 2)'));
    await tester.pumpAndSettle();

    expect(find.text('Birinci'), findsOneWidget);
    expect(find.text('İkinci'), findsOneWidget);
    final pages = [
      for (var i = 0; i < adapter.calls.length; i++)
        if (adapter.calls[i] == '/notifications') adapter.requestQueries[i]['page'],
    ];
    expect(pages, [1, 2]);
    expect(find.textContaining('Daha fazla göster'), findsNothing);
  });
}
