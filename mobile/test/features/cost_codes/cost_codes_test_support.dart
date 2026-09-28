import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/cost_codes/cost_codes_routes.dart';
import 'package:arvend/features/cost_codes/data/cost_codes_providers.dart';
import 'package:arvend/features/cost_codes/data/cost_codes_repository.dart';
import 'package:arvend/features/cost_codes/domain/cost_code.dart';

import '../suppliers/suppliers_test_support.dart' show FakeAuth, buildUser;

export '../suppliers/suppliers_test_support.dart' show goldenTheme, loadAppFonts, forbidden;

/// Maliyet kodu testlerinin ortak kurulumu: sahte depo (ağ YOK), persona
/// kullanıcıları ve gerçek rota ağacı (`costCodesRoutes`, `/diger` altında).
/// Kullanıcı/font/tema yardımcıları tedarikçi testleriyle paylaşılır (aynı
/// "katalog" grubu).

/// Sahip: kaba rol admin + tam izin.
final ccOwnerUser = buildUser(
  id: 'owner',
  role: UserRole.admin,
  roleCode: 'owner',
  permissions: {kCostCodesReadPermission, kCostCodesManagePermission},
);

/// Finans: kaba rol `kullanici`, `.manage` var (requireAdmin YOK).
final ccFinanceUser = buildUser(
  id: 'finance',
  roleCode: 'finance',
  permissions: {kCostCodesReadPermission, kCostCodesManagePermission},
);

/// Proje yöneticisi benzeri: yalnızca görüntüleme.
final ccReadOnlyUser = buildUser(id: 'pm', roleCode: 'project_manager', permissions: {kCostCodesReadPermission});

/// Saha: maliyet kodu izni yok.
final ccNoAccessUser = buildUser(id: 'field', roleCode: 'field', permissions: {'projects.read'});

/// İzin kümesi boş -- KATI kontrol erişim VERMEZ.
final ccEmptyPermissionsUser = buildUser(id: 'legacy');

/// Backend sırası: kod ASC.
const kCostCodeFixtures = <OrganizationCostCode>[
  OrganizationCostCode(id: 'c1', code: 'EKP-001', name: 'Kule Vinç Kirası', description: 'Aylık kiralama, operatör dahil', category: 'Ekipman'),
  OrganizationCostCode(id: 'c2', code: 'GNL-001', name: 'Şantiye Genel Giderleri', description: 'Elektrik, su, güvenlik'),
  OrganizationCostCode(id: 'c3', code: 'ISC-001', name: 'Kalıp İşçiliği', description: 'Ahşap ve plywood kalıp', category: 'İşçilik'),
  OrganizationCostCode(id: 'c4', code: 'ISC-002', name: 'Demir Bağlama İşçiliği', category: 'İşçilik'),
  OrganizationCostCode(id: 'c5', code: 'MLZ-001', name: 'Hazır Beton', description: 'C30/37 pompalı hazır beton', category: 'Malzeme'),
  OrganizationCostCode(id: 'c6', code: 'MLZ-002', name: 'İnşaat Demiri', description: 'B500C nervürlü', category: 'Malzeme'),
  OrganizationCostCode(id: 'c7', code: 'MLZ-003', name: 'Tuğla', category: 'Malzeme', isActive: false),
  OrganizationCostCode(id: 'c8', code: 'MLZ-004', name: 'Alçı Sıva', category: 'malzeme '),
  OrganizationCostCode(id: 'c9', code: 'TAS-001', name: 'Elektrik Taşeronu', description: 'Tesisat ve pano montajı', category: 'Taşeron'),
];

class FakeCostCodesRepository implements CostCodesRepository {
  FakeCostCodesRepository([List<OrganizationCostCode> initial = kCostCodeFixtures]) : items = [...initial];

  final List<OrganizationCostCode> items;
  final List<String> calls = [];
  final List<(String, CostCodeInput)> created = [];
  final List<(String, CostCodeInput)> updated = [];
  Object? listError;
  Object? writeError;

  /// Verilirse yazma çağrıları bu tamamlanana kadar bekler (kayıt sürerken
  /// formun davranışını denemek için).
  Completer<void>? writeGate;

  @override
  Future<List<OrganizationCostCode>> list() async {
    calls.add('list');
    if (listError != null) throw listError!;
    return [...items];
  }

  @override
  Future<OrganizationCostCode> get(String id) async {
    calls.add('get:$id');
    return items.firstWhere(
      (c) => c.id == id,
      orElse: () =>
          throw const ApiException(statusCode: 404, message: 'maliyet kodu bulunamadı', kind: ApiErrorKind.notFound),
    );
  }

  @override
  Future<OrganizationCostCode> create({required String code, required CostCodeInput input}) async {
    calls.add('create');
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
    created.add((code, input));
    final c = OrganizationCostCode(
      id: 'new${items.length + 1}',
      code: code,
      name: input.name,
      description: input.description,
      category: input.category,
    );
    items.add(c);
    return c;
  }

  @override
  Future<OrganizationCostCode> update(String id, CostCodeInput input) async {
    calls.add('update:$id');
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
    updated.add((id, input));
    final i = items.indexWhere((c) => c.id == id);
    final old = items[i];
    final c = OrganizationCostCode(
      id: id,
      code: old.code,
      name: input.name,
      description: input.description,
      category: input.category,
      isActive: old.isActive,
    );
    items[i] = c;
    return c;
  }

  void _setActive(String id, bool active) {
    final i = items.indexWhere((c) => c.id == id);
    final o = items[i];
    items[i] = OrganizationCostCode(
      id: o.id,
      code: o.code,
      name: o.name,
      description: o.description,
      category: o.category,
      isActive: active,
    );
  }

  @override
  Future<void> archive(String id) async {
    calls.add('archive:$id');
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
    _setActive(id, false);
  }

  @override
  Future<void> reactivate(String id) async {
    calls.add('reactivate:$id');
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
    _setActive(id, true);
  }
}

/// Gerçek uygulamadaki gibi: `/diger` altında `costCodesRoutes`.
Widget buildCostCodesApp({
  required User user,
  required FakeCostCodesRepository repo,
  String initialLocation = kCostCodesPath,
  ThemeData? theme,
}) {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/diger',
        builder: (_, _) => const Scaffold(body: Center(child: Text('Diğer'))),
        routes: costCodesRoutes,
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(() => FakeAuth(user)),
      costCodesRepositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: theme ?? AppTheme.light(),
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      routerConfig: router,
    ),
  );
}
