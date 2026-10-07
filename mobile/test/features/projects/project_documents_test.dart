import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/widgets/quick_action_button.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/domain/project_lock_text.dart';
import 'package:arvend/features/projects/presentation/project_detail_screen.dart';

import '../../test_utils/fake_api_client.dart';
import '../contract_co/contract_co_test_support.dart' as cc;

/// Proje > Dökümanlar (Dosyalar) ve Operasyon > Görevler: kilit durumu,
/// fotoğraf ızgarası, dosya listesi.

final _fieldManager = User.fromJson({
  'id': 'u1',
  'organization_id': 'org1',
  'username': 'saha',
  'full_name': 'Saha Şefi',
  'role': 'kullanici',
  'is_active': true,
  'must_change_password': false,
  'onboarding_completed': true,
  'onboarding_step': 'completed',
  'permissions': [
    'projects.read',
    'projects.tasks.read',
    'projects.tasks.create',
    'projects.tasks.update',
    'projects.operations.read',
    'projects.operations.manage',
  ],
});

Map<String, dynamic> photoJson(String id, {String stage = 'progress', String description = '', String createdAt = '2026-10-01T09:00:00Z'}) => {
      'id': id,
      'original_name': '$id.jpg',
      'mime_type': 'image/jpeg',
      'size_bytes': 2048,
      'stage': stage,
      'description': description,
      'created_at': createdAt,
    };

Map<String, dynamic> fileJson(String id, {String name = 'sozlesme.pdf', int size = 20971520, String description = ''}) => {
      'id': id,
      'original_name': name,
      'mime_type': 'application/pdf',
      'size_bytes': size,
      'category': 'contract',
      'description': description,
      'created_at': '2026-10-01T09:00:00Z',
    };

Map<String, dynamic> taskJson() => {
      'id': 't1',
      'schedule_item_id': null,
      'title': 'Kalıp sökümü',
      'description': '',
      'assigned_employee_id': null,
      'assigned_name': '',
      'priority': 'normal',
      'status': 'todo',
      'due_date': null,
      'completed_at': null,
      'is_overdue': false,
    };

const _opsSummary = {
  'open_task_count': 1,
  'completed_task_count': 0,
  'overdue_task_count': 0,
  'active_member_count': 2,
};

Future<FakeHttpClientAdapter> pumpProject(
  WidgetTester tester, {
  String status = 'active',
  String? group,
  String? view,
  List<Map<String, dynamic>> photos = const [],
  List<Map<String, dynamic>> files = const [],
  Map<String, List<ScriptedResponse>> extra = const {},
  Size size = const Size(400, 1400),
}) async {
  final adapter = FakeHttpClientAdapter(script: {
    '/projects/p1/photos': [for (var i = 0; i < 3; i++) (status: 200, body: {'photos': photos})],
    '/projects/p1/files': [for (var i = 0; i < 3; i++) (status: 200, body: {'files': files})],
    '/projects/p1/tasks': [for (var i = 0; i < 3; i++) (status: 200, body: {'tasks': [taskJson()]})],
    '/projects/p1/operations-summary': [for (var i = 0; i < 3; i++) (status: 200, body: _opsSummary)],
    '/projects/p1/notes': [for (var i = 0; i < 3; i++) (status: 200, body: {'notes': <dynamic>[]})],
    ...extra,
  });
  final client = await buildFakeApiClient(adapter);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(client),
        authControllerProvider.overrideWith(() => cc.FakeAuth(_fieldManager)),
        projectDetailProvider.overrideWith((ref, id) async => cc.sampleProject(status: status)),
      ],
      child: MaterialApp(home: ProjectDetailScreen(projectId: 'p1', initialGroup: group, initialView: view)),
    ),
  );
  await tester.pumpAndSettle();
  return adapter;
}

void main() {
  setUpAll(() => initializeDateFormatting('tr_TR'));

  group('kapalı proje (tamamlandı/iptal)', () {
    testWidgets('Dosyalar: yükleme düğmeleri yok, nedeni yazılı', (tester) async {
      await pumpProject(tester, status: 'completed', group: 'dokumanlar', files: [fileJson('f1')]);

      expect(find.text(kProjectUploadsLockedText), findsOneWidget);
      expect(find.text('Fotoğraf Çek'), findsNothing);
      expect(find.text('Galeriden Seç'), findsNothing);
      expect(find.text('Dosya Seç'), findsNothing);
      // Silme backend'de kapalı projede de serbest.
      expect(find.byTooltip('Dosyayı sil'), findsOneWidget);
    });

    testWidgets('Görevler: "Görev Ekle" yok, nedeni yazılı; tamamlama kutusu duruyor', (tester) async {
      await pumpProject(tester, status: 'cancelled', group: 'operasyon', view: 'gorevler');

      expect(find.text(kProjectTasksLockedText), findsOneWidget);
      expect(find.text('Görev Ekle'), findsNothing);
      expect(find.byType(Checkbox), findsOneWidget);
    });

    testWidgets('Özet: "Görev Ekle" ve "Fotoğraf Ekle" hızlı işlemleri yok', (tester) async {
      await pumpProject(tester, status: 'completed');

      expect(find.widgetWithText(QuickActionButton, 'Görev Ekle'), findsNothing);
      expect(find.widgetWithText(QuickActionButton, 'Fotoğraf Ekle'), findsNothing);
    });

    testWidgets('açık projede düğmeler yerinde', (tester) async {
      await pumpProject(tester, group: 'dokumanlar');

      expect(find.text(kProjectUploadsLockedText), findsNothing);
      expect(find.text('Fotoğraf Çek'), findsOneWidget);
      expect(find.text('Dosya Seç'), findsOneWidget);
    });
  });
}
