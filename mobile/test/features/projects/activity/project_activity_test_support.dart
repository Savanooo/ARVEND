import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/activity/data/project_activity_providers.dart';
import 'package:arvend/features/projects/activity/data/project_activity_repository.dart';
import 'package:arvend/features/projects/activity/domain/project_event.dart';
import 'package:arvend/features/projects/activity/presentation/project_activity_screen.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';

import '../../contract_co/contract_co_test_support.dart' as cc;

/// Proje Aktivite testlerinin ortak kurulumu: sahte olay deposu (ağ YOK),
/// personalar ve sunucu sırasıyla (created_at ASC) olay fikstürü.

final activityOwner = cc.buildUser(
  id: 'owner',
  role: UserRole.admin,
  roleCode: 'owner',
  permissions: {'projects.read', 'projects.finance.read'},
);

/// Proje Yöneticisi: projeyi görür, finans (tutar) izni YOK.
final activityPm = cc.buildUser(
  id: 'pm',
  roleCode: 'project_manager',
  permissions: {'projects.read', 'projects.contracts.read', 'projects.tasks.read'},
);

ProjectEvent _e(String id, String type, String at, [Map<String, dynamic> metadata = const {}]) =>
    ProjectEvent(id: id, eventType: type, createdAt: at, metadata: metadata);

/// Sunucu sırası: en eski önce.
final kActivityEvents = <ProjectEvent>[
  _e('ev1', 'project_created', '2026-09-27T06:10:00Z', {'project_no': 'PRJ-2026-0007'}),
  _e('ev2', 'payment_plan_created', '2026-09-27T07:00:00Z', {'item_id': 'i1', 'name': 'Peşinat', 'planned_amount': 250000}),
  _e('ev3', 'collection_received', '2026-09-28T08:15:00Z', {'collection_id': 'c1', 'amount': 250000}),
  _e('ev4', 'expense_added', '2026-09-28T11:40:00Z', {'expense_id': 'e1', 'amount': 84500, 'category': 'material'}),
  // 21:30Z = İstanbul'da ertesi gün 00:30 -> 29 Eylül grubunda.
  _e('ev5', 'invoice_status_changed', '2026-09-28T21:30:00Z', {'invoice_id': 'f1', 'status': 'paid'}),
  _e('ev6', 'change_order_created', '2026-09-29T06:05:00Z', {
    'change_order_id': 'co1',
    'title': 'Toplantı odası cam bölme',
    'grand_total': 96000,
  }),
  _e('ev7', 'schedule_updated', '2026-09-29T07:20:00Z', {'schedule_item_id': 's1', 'name': 'Kaba inşaat', 'status': 'active'}),
  _e('ev8', 'expense_voided', '2026-09-29T08:00:00Z', {'expense_id': 'e2', 'reason': 'Mükerrer giriş'}),
  _e('ev9', 'project_status_changed', '2026-09-29T09:00:00Z', {'from': 'planned', 'to': 'active'}),
  _e('ev10', 'yeni_bir_olay_tipi', '2026-09-29T10:00:00Z'),
];

class FakeActivityRepository implements ProjectActivityRepository {
  FakeActivityRepository({List<ProjectEvent>? fixture, this.error}) : fixture = fixture ?? kActivityEvents;

  final List<ProjectEvent> fixture;
  final Object? error;
  final List<String> calls = [];

  @override
  Future<List<ProjectEvent>> events(String projectId) async {
    calls.add(projectId);
    if (error != null) throw error!;
    return fixture;
  }
}

const activityForbidden =
    ApiException(statusCode: 403, message: 'bu işlem için yetkiniz yok', kind: ApiErrorKind.forbidden);

/// Oturum hiç yüklenmiyor (ör. /auth/me yolda) -- ekran istek atmamalı.
class PendingAuth extends AuthController {
  @override
  Future<User?> build() => Completer<User?>().future;
}

Widget buildActivityApp({
  User? user,
  AuthController Function()? auth,
  required FakeActivityRepository repo,
  ThemeData? theme,
}) {
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(auth ?? () => cc.FakeAuth(user!)),
      projectActivityRepositoryProvider.overrideWithValue(repo),
      projectDetailProvider.overrideWith((ref, id) async => cc.sampleProject()),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme ?? AppTheme.light(),
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: const ProjectActivityScreen(projectId: 'p1'),
    ),
  );
}
