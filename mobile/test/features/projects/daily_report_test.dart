import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/files/file_share.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/daily_report/daily_report_routes.dart';

import '../../test_utils/fake_api_client.dart';
import '../../test_utils/fake_file_sharer.dart';
import '../contract_co/contract_co_test_support.dart' as cc;
import 'form_test_support.dart' show requestBodyFor;

/// Günlük şantiye raporu (backend migration 0071): liste (bugün + geçmiş),
/// günün formu (puantaj önerisi, hava, taşeronlar), kaydet / kaydet ve
/// gönder, okuma görünümü, PDF paylaşımı.

const _day = '2026-10-10';
const _dayPath = '/projects/p1/daily-reports/$_day';

final _field = cc.buildUser(
  id: 'field',
  roleCode: 'field',
  permissions: const {'projects.read', 'projects.operations.read', 'projects.operations.manage'},
);

final _viewer = cc.buildUser(
  id: 'viewer',
  roleCode: 'finance',
  permissions: const {'projects.read', 'projects.operations.read'},
);

Map<String, dynamic> _project({String status = 'active'}) => {
      'id': 'p1',
      'project_no': 'PRJ-2026-0007',
      'name': 'Kadıköy Konut',
      'customer_name': 'Müşteri',
      'project_type': 'insaat',
      'status': status,
      'contract_amount': 0,
      'currency': 'TRY',
      'description': '',
      'created_at': '2026-09-01T00:00:00Z',
    };

Map<String, dynamic> _report({
  bool exists = false,
  String status = 'draft',
  int ownWorkers = 0,
  String weather = '',
  String workDone = '',
  List<Map<String, dynamic>> subs = const [],
}) =>
    {
      'exists': exists,
      'id': exists ? 'r1' : '',
      'project_id': 'p1',
      'report_date': _day,
      'weather': weather,
      'temperature_c': null,
      'own_workers': ownWorkers,
      'work_done': workDone,
      'issues': '',
      'materials': '',
      'notes': '',
      'status': status,
      'submitted_at': status == 'submitted' ? '2026-10-10T15:30:00Z' : null,
      'submitted_by_name': status == 'submitted' ? 'Saha Şefi' : '',
      'created_by_name': exists ? 'Saha Şefi' : '',
      'updated_at': exists ? '2026-10-10T15:00:00Z' : null,
      'subcontractors': subs,
      'suggested_own_workers': 5,
      'completed_tasks': [
        {'id': 't1', 'title': 'Kalıp söküldü', 'assigned_name': 'Ali Usta'},
      ],
      'photos': [],
      'subcontractor_options': [
        {'supplier_id': 's1', 'name': 'Elektrikçi Hasan', 'specialty': 'Elektrik', 'workers': 0, 'work_note': ''},
      ],
    };

Map<String, dynamic> _list({List<Map<String, dynamic>> reports = const []}) => {
      'reports': reports,
      'today': '2026-10-15',
    };

Map<String, dynamic> _listItem(String date, {String status = 'submitted'}) => {
      'id': 'r-$date',
      'report_date': date,
      'weather': 'sunny',
      'temperature_c': 18,
      'own_workers': 4,
      'subcontractor_workers': 3,
      'status': status,
      'work_done': 'Kolon betonu döküldü',
      'created_by_name': 'Saha Şefi',
      'photo_count': 2,
    };

Future<FakeHttpClientAdapter> _pump(
  WidgetTester tester, {
  required User user,
  required Map<String, List<ScriptedResponse>> script,
  required String initial,
  FileSharer? sharer,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final adapter = FakeHttpClientAdapter(script: script);
  final client = await buildFakeApiClient(adapter);
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/projeler/:id',
        builder: (c, s) => const Scaffold(body: Text('proje')),
        routes: dailyReportRoutes,
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => cc.FakeAuth(user)),
        if (sharer != null) fileSharerProvider.overrideWithValue(sharer),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        locale: const Locale('tr', 'TR'),
        supportedLocales: const [Locale('tr', 'TR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return adapter;
}

void main() {
  setUpAll(() async => initializeDateFormatting('tr_TR'));

  testWidgets('liste: bugün yazılmadıysa "Bugünün Raporunu Yaz", geçmiş günler özetle', (tester) async {
    await _pump(tester, user: _field, initial: '/projeler/p1/gunluk-rapor', script: {
      '/projects/p1': [(status: 200, body: _project())],
      '/projects/p1/daily-reports': [
        (status: 200, body: _list(reports: [_listItem('2026-10-14'), _listItem('2026-10-13', status: 'draft')])),
      ],
    });
    expect(find.byKey(const ValueKey('gunluk-rapor-yaz')), findsOneWidget);
    expect(find.byKey(const ValueKey('gunluk-rapor-2026-10-14')), findsOneWidget);
    expect(find.textContaining('Güneşli 18°C · 7 kişi · 2 fotoğraf'), findsNWidgets(2));
    expect(find.text('Gönderildi'), findsOneWidget);
    expect(find.text('Taslak'), findsOneWidget);
  });

  testWidgets('liste: yazma izni olmayan ya da kapalı projede "Yaz" düğmesi yok', (tester) async {
    await _pump(tester, user: _viewer, initial: '/projeler/p1/gunluk-rapor', script: {
      '/projects/p1': [(status: 200, body: _project())],
      '/projects/p1/daily-reports': [(status: 200, body: _list())],
    });
    expect(find.byKey(const ValueKey('gunluk-rapor-yaz')), findsNothing);
    expect(find.text('Bugünün raporu henüz yazılmadı.'), findsOneWidget);
  });

  testWidgets('yazılmamış gün: puantaj önerisiyle dolar; hava, taşeron ve iş girilip kaydedilir', (tester) async {
    final adapter = await _pump(tester, user: _field, initial: '/projeler/p1/gunluk-rapor/$_day', script: {
      '/projects/p1': [(status: 200, body: _project())],
      _dayPath: [
        (status: 200, body: _report()),
        // PUT yanıtı, ardından tazeleme.
        (
          status: 200,
          body: _report(exists: true, ownWorkers: 5, weather: 'sunny', workDone: 'Kolon betonu', subs: [
            {'supplier_id': 's1', 'name': 'Elektrikçi Hasan', 'specialty': 'Elektrik', 'workers': 3, 'work_note': 'pano'},
          ]),
        ),
        (
          status: 200,
          body: _report(exists: true, ownWorkers: 5, weather: 'sunny', workDone: 'Kolon betonu', subs: [
            {'supplier_id': 's1', 'name': 'Elektrikçi Hasan', 'specialty': 'Elektrik', 'workers': 3, 'work_note': 'pano'},
          ]),
        ),
      ],
      '/projects/p1/daily-reports': [(status: 200, body: _list())],
    });
    // Kendi ekibimiz puantajdan (5) gelir; o gün tamamlanan görev görünür.
    final own = find.descendant(of: find.byKey(const ValueKey('gunluk-rapor-kendi-ekip')), matching: find.byType(TextField));
    expect(tester.widget<TextField>(own).controller!.text, '5');
    expect(find.textContaining('Kalıp söküldü'), findsOneWidget);
    expect(find.byKey(const ValueKey('gunluk-rapor-gonder')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('gunluk-rapor-hava-sunny')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('gunluk-rapor-taseron-ekle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('gunluk-rapor-secenek-s1')));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('gunluk-rapor-taseron-s1'));
    expect(row, findsOneWidget);
    await tester.tap(find.descendant(of: row, matching: find.byTooltip('Artır')));
    await tester.tap(find.descendant(of: row, matching: find.byTooltip('Artır')));
    await tester.enterText(find.descendant(of: row, matching: find.widgetWithText(TextField, 'Ne yaptı?')), 'pano');
    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey('gunluk-rapor-yapilan')), matching: find.byType(TextField)),
      'Kolon betonu',
    );
    await tester.pumpAndSettle();
    expect(find.text('Toplam 8 kişi'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('gunluk-rapor-kaydet')));
    await tester.pumpAndSettle();
    final body = requestBodyFor(adapter, _dayPath);
    expect(body['weather'], 'sunny');
    expect(body['own_workers'], 5);
    expect(body['work_done'], 'Kolon betonu');
    expect(body['subcontractors'], [
      {'supplier_id': 's1', 'workers': 3, 'work_note': 'pano'},
    ]);
    expect(find.text('Rapor kaydedildi.'), findsOneWidget);
  });

  testWidgets('"Kaydet ve Gönder" önce kaydeder sonra gönderir', (tester) async {
    final sent = _report(exists: true, status: 'submitted', ownWorkers: 5, workDone: 'İş');
    final adapter = await _pump(tester, user: _field, initial: '/projeler/p1/gunluk-rapor/$_day', script: {
      '/projects/p1': [(status: 200, body: _project())],
      _dayPath: [
        (status: 200, body: _report()),
        (status: 200, body: _report(exists: true, ownWorkers: 5, workDone: 'İş')),
        (status: 200, body: sent),
        (status: 200, body: sent),
      ],
      '$_dayPath/submit': [(status: 200, body: sent)],
      '/projects/p1/daily-reports': [
        (status: 200, body: _list()),
        (status: 200, body: _list()),
      ],
    });
    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey('gunluk-rapor-yapilan')), matching: find.byType(TextField)),
      'İş',
    );
    await tester.tap(find.byKey(const ValueKey('gunluk-rapor-gonder')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gönder'));
    await tester.pumpAndSettle();

    final putAt = adapter.methods.indexOf('PUT');
    final postAt = adapter.calls.indexOf('$_dayPath/submit');
    expect(putAt, greaterThanOrEqualTo(0));
    expect(postAt, greaterThan(putAt), reason: 'önce kaydedilir, sonra gönderilir');
    expect(find.text('Rapor gönderildi.'), findsOneWidget);
    expect(find.byKey(const ValueKey('gunluk-rapor-gonder')), findsNothing, reason: 'gönderilmişte yalnızca Kaydet kalır');
    expect(find.text('Gönderildi'), findsOneWidget);
  });

  testWidgets('yazma izni yoksa rapor okunur, form ve düğmeler yok', (tester) async {
    await _pump(tester, user: _viewer, initial: '/projeler/p1/gunluk-rapor/$_day', script: {
      '/projects/p1': [(status: 200, body: _project())],
      _dayPath: [
        (
          status: 200,
          body: _report(exists: true, status: 'submitted', ownWorkers: 4, weather: 'rainy', workDone: 'Duvar örüldü', subs: [
            {'supplier_id': 's1', 'name': 'Elektrikçi Hasan', 'specialty': '', 'workers': 2, 'work_note': 'kablo'},
          ]),
        ),
      ],
    });
    expect(find.text('Duvar örüldü'), findsOneWidget);
    expect(find.textContaining('Elektrikçi Hasan: 2 kişi'), findsOneWidget);
    expect(find.textContaining('Toplam 6 kişi'), findsOneWidget);
    expect(find.byKey(const ValueKey('gunluk-rapor-kaydet')), findsNothing);
    expect(find.byKey(const ValueKey('gunluk-rapor-hava-sunny')), findsNothing);
  });

  testWidgets('kapalı projede form açılmaz', (tester) async {
    await _pump(tester, user: _field, initial: '/projeler/p1/gunluk-rapor/$_day', script: {
      '/projects/p1': [(status: 200, body: _project(status: 'completed'))],
      _dayPath: [(status: 200, body: _report())],
    });
    expect(find.byKey(const ValueKey('gunluk-rapor-kaydet')), findsNothing);
    expect(find.text('Bu günün raporu yazılmamış.'), findsOneWidget);
  });

  testWidgets('PDF paylaşım menüsüyle gider', (tester) async {
    final sharer = FakeFileSharer();
    await _pump(tester, user: _viewer, sharer: sharer, initial: '/projeler/p1/gunluk-rapor/$_day', script: {
      '/projects/p1': [(status: 200, body: _project())],
      _dayPath: [(status: 200, body: _report(exists: true, status: 'submitted', workDone: 'İş'))],
      '$_dayPath/pdf': [(status: 200, body: '%PDF-1.4'.codeUnits)],
    });
    await tester.tap(find.byKey(const ValueKey('gunluk-rapor-pdf')));
    await tester.pumpAndSettle();
    expect(sharer.files, hasLength(1));
    expect(sharer.files.single.filename, 'Gunluk-Rapor-PRJ-2026-0007-$_day.pdf');
    expect(sharer.files.single.mimeType, 'application/pdf');
  });
}
