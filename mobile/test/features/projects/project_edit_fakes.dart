import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/data/project_edit_repository.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/domain/project_edit.dart';
import 'package:arvend/features/projects/presentation/project_detail_screen.dart';
import 'package:arvend/features/projects/projects_routes.dart';

import '../dashboard/fixtures.dart' show kAllPermissions;

class FakeProjectEditRepository implements ProjectEditRepository {
  FakeProjectEditRepository({ProjectEditable? project}) : current = project ?? sampleEditable();

  ProjectEditable current;
  Object? loadError;
  Object? saveError;

  /// Verilirse kayıt bu tamamlanana kadar sürer.
  Completer<void>? saveGate;
  final calls = <String>[];
  final updates = <({String id, ProjectEditInput input})>[];

  @override
  Future<ProjectEditable> load(String projectId) async {
    calls.add('load:$projectId');
    if (loadError != null) throw loadError!;
    return current;
  }

  @override
  Future<ProjectEditable> update(String projectId, ProjectEditInput input) async {
    calls.add('update:$projectId');
    if (saveGate != null) await saveGate!.future;
    if (saveError != null) throw saveError!;
    updates.add((id: projectId, input: input));
    return current;
  }
}

ProjectEditable sampleEditable({String status = 'active'}) => ProjectEditable(
      id: 'p1',
      projectNo: 'PRJ-2026-0007',
      name: 'Kadıköy Ofis Tadilatı',
      projectType: 'Tadilat',
      status: status,
      startDate: '2026-09-01',
      endDate: '2026-12-15',
      description: 'Zemin kat asma tavan ve bölme duvar işleri',
      internalNotes: 'Malzeme teslimi sabah 08:00 öncesi',
      customerName: 'Moda Mimarlık Ltd.',
      contractAmount: 1250000,
      currency: 'TRY',
      sourceOfferNo: 'TKL-2026-0031',
      sourceRevisionNo: 2,
    );

User projectUser({UserRole role = UserRole.kullanici, required Iterable<String> permissions}) => User(
      id: 'u1',
      organizationId: 'org-1',
      username: 'test',
      fullName: 'Test Kullanıcı',
      role: role,
      isActive: true,
      mustChangePassword: false,
      onboardingCompleted: true,
      onboardingStep: 'completed',
      organizationName: 'Deneme Firma',
      permissions: permissions.toSet(),
    );

final projectOwner = projectUser(role: UserRole.admin, permissions: kAllPermissions);

/// Proje Yöneticisi benzeri: düzenleyebilir ama finans göremez.
final projectEditorNoFinance = projectUser(permissions: const ['projects.read', 'projects.update']);

/// Yalnızca görüntüleme.
final projectViewer = projectUser(permissions: const ['projects.read']);

class FakeAuthController extends AuthController {
  FakeAuthController(this._user);
  final User? _user;

  @override
  Future<User?> build() async => _user;
}

ThemeData goldenTheme() {
  final theme = AppTheme.light();
  final elevated = theme.elevatedButtonTheme.style;
  final buttonText = elevated?.textStyle?.resolve(const <WidgetState>{});
  return theme.copyWith(
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Inter'),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: elevated?.copyWith(
        textStyle: WidgetStatePropertyAll((buttonText ?? const TextStyle()).copyWith(fontFamily: 'Inter')),
      ),
    ),
  );
}

Future<void> loadAppFonts() async {
  final manifest = json.decode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

Future<void> withRealShadows(Future<void> Function() body) async {
  debugDisableShadows = false;
  try {
    await body();
  } finally {
    debugDisableShadows = true;
  }
}

Project sampleProject() => Project.fromJson({
      'id': 'p1',
      'project_no': 'PRJ-2026-0007',
      'name': 'Kadıköy Ofis Tadilatı',
      'project_type': 'Tadilat',
      'customer_name': 'Moda Mimarlık Ltd.',
      'contract_amount': 1250000,
      'currency': 'TRY',
      'status': 'active',
      'start_date': '2026-09-01',
      'end_date': '2026-12-15',
      'description': '',
      'created_at': '2026-09-01T08:00:00Z',
    });

/// `/projeler/:id` + `projectEditRoutes` alt rotası -- gerçek router ile
/// aynı yerleşim.
Widget projectEditApp({
  required User? user,
  required FakeProjectEditRepository repo,
  required ApiClient offlineClient,
  String location = '/projeler/p1/duzenle',
}) {
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/projeler',
        builder: (_, _) => const Scaffold(body: Center(child: Text('Projeler'))),
        routes: [
          GoRoute(
            path: ':id',
            builder: (_, state) => ProjectDetailScreen(projectId: state.pathParameters['id']!),
            routes: projectEditRoutes,
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      // Detay ekranının (düzenleme ekranının altındaki sayfa) kendi
      // sekmelerinin istekleri betiksiz sahte istemciye düşer ve hata
      // durumuna geçer -- gerçek ağ yok.
      apiClientProvider.overrideWithValue(offlineClient),
      authControllerProvider.overrideWith(() => FakeAuthController(user)),
      projectEditRepositoryProvider.overrideWithValue(repo),
      projectDetailProvider.overrideWith((ref, id) async => sampleProject()),
    ],
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: goldenTheme(),
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      routerConfig: router,
    ),
  );
}
