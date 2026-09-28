import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/suppliers/data/suppliers_providers.dart';
import 'package:arvend/features/suppliers/data/suppliers_repository.dart';
import 'package:arvend/features/suppliers/domain/supplier.dart';
import 'package:arvend/features/suppliers/suppliers_routes.dart';

/// Tedarikçi testlerinin ortak kurulumu: sahte depo (ağ YOK), persona
/// kullanıcıları, gerçek rota ağacı (`suppliersRoutes`, `/diger` altında)
/// ve golden testleri için uygulama fontları.

User buildUser({
  String id = 'u1',
  UserRole role = UserRole.kullanici,
  Set<String> permissions = const {},
  String roleCode = 'custom',
}) =>
    User(
      id: id,
      organizationId: 'org1',
      username: 'test.$id',
      fullName: 'Test Kullanıcı',
      role: role,
      isActive: true,
      mustChangePassword: false,
      onboardingCompleted: true,
      onboardingStep: 'completed',
      organizationName: 'Deneme Yapı',
      organizationRoleCode: roleCode,
      permissions: permissions,
    );

/// Sahip: kaba rol admin + tam izin.
final ownerUser = buildUser(
  id: 'owner',
  role: UserRole.admin,
  roleCode: 'owner',
  permissions: {kSuppliersReadPermission, kSuppliersManagePermission, 'projects.read'},
);

/// Satın almacı: kaba rol `kullanici`, ama `.manage` var -- tedarikçiler
/// requireAdmin İSTEMEZ, yönetebilmeli.
final managerUser = buildUser(
  id: 'manager',
  permissions: {kSuppliersReadPermission, kSuppliersManagePermission},
);

/// Yalnızca görüntüleme (Proje Yöneticisi/Saha benzeri).
final readOnlyUser = buildUser(id: 'viewer', permissions: {kSuppliersReadPermission, 'projects.read'});

/// Tedarikçi izni hiç yok.
final noAccessUser = buildUser(id: 'field', permissions: {'projects.read', 'projects.tasks.read'});

/// İzin kümesi boş (eski oturum) -- KATI kontrol erişim VERMEZ.
final emptyPermissionsUser = buildUser(id: 'legacy');

const kSupplierFixtures = <OrganizationSupplier>[
  OrganizationSupplier(
    id: 's1',
    code: 'TED-001',
    legalName: 'Kaya Yapı Malzemeleri Sanayi ve Ticaret A.Ş.',
    tradeName: 'Kaya Yapı',
    taxNumber: '5840123456',
    taxOffice: 'Kozyatağı',
    contactName: 'Ahmet Kaya',
    email: 'satis@kayayapi.com.tr',
    phone: '0216 555 10 20',
    address: 'Esenşehir Mah. Sanayi Cad. No:12 Ümraniye',
    city: 'İstanbul',
    country: 'Türkiye',
    specialty: 'Kaba yapı malzemeleri',
    notes: 'Çimento ve agrega ana tedarikçisi. Ödeme vadesi 30 gün.',
    ibanSet: true,
    createdAt: '2026-09-12T09:00:00Z',
    updatedAt: '2026-09-27T11:30:00Z',
  ),
  OrganizationSupplier(
    id: 's2',
    code: 'TED-002',
    legalName: 'Demir Profil Çelik Ltd. Şti.',
    contactName: 'Mehmet Demir',
    phone: '0312 444 22 33',
    city: 'Ankara',
    country: 'Türkiye',
    createdAt: '2026-09-12T09:05:00Z',
    updatedAt: '2026-09-12T09:05:00Z',
  ),
  OrganizationSupplier(
    id: 's3',
    code: 'TED-003',
    legalName: 'Ege Elektrik Taahhüt Hizmetleri',
    tradeName: 'Ege Elektrik',
    email: 'teklif@egeelektrik.com',
    city: 'İzmir',
    country: 'Türkiye',
    specialty: 'Elektrik',
    ibanSet: true,
    createdAt: '2026-09-14T08:00:00Z',
    updatedAt: '2026-09-20T08:00:00Z',
  ),
  OrganizationSupplier(
    id: 's4',
    code: 'TED-004',
    legalName: 'Işık Boya Kimya San. Tic. Ltd. Şti.',
    tradeName: 'Işık Boya',
    city: 'Bursa',
    country: 'Türkiye',
    isActive: false,
    createdAt: '2026-09-01T08:00:00Z',
    updatedAt: '2026-09-25T08:00:00Z',
  ),
  OrganizationSupplier(
    id: 's5',
    code: 'TED-005',
    legalName: 'Öztürk Hafriyat Nakliyat',
    phone: '0262 333 44 55',
    city: 'Kocaeli',
    country: 'Türkiye',
    createdAt: '2026-09-16T08:00:00Z',
    updatedAt: '2026-09-16T08:00:00Z',
  ),
];

const forbidden = ApiException(statusCode: 403, message: 'bu işlem için yetkiniz yok', kind: ApiErrorKind.forbidden);

/// Bellek içi sahte depo: çağrıları kaydeder, istenirse hata fırlatır.
class FakeSuppliersRepository implements SuppliersRepository {
  FakeSuppliersRepository([List<OrganizationSupplier> initial = kSupplierFixtures]) : items = [...initial];

  final List<OrganizationSupplier> items;
  final List<String> calls = [];
  final List<SupplierInput> created = [];
  final List<(String, SupplierInput)> updated = [];
  Object? listError;
  Object? getError;
  Object? writeError;

  /// Verilirse yazma çağrıları bu tamamlanana kadar bekler (kayıt sürerken
  /// formun davranışını denemek için).
  Completer<void>? writeGate;

  @override
  Future<List<OrganizationSupplier>> list() async {
    calls.add('list');
    if (listError != null) throw listError!;
    return [...items];
  }

  @override
  Future<OrganizationSupplier> get(String id) async {
    calls.add('get:$id');
    if (getError != null) throw getError!;
    return items.firstWhere(
      (s) => s.id == id,
      orElse: () => throw const ApiException(statusCode: 404, message: 'tedarikçi bulunamadı', kind: ApiErrorKind.notFound),
    );
  }

  @override
  Future<OrganizationSupplier> create(SupplierInput input) async {
    calls.add('create');
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
    created.add(input);
    final s = OrganizationSupplier(
      id: 'new${items.length + 1}',
      code: input.code,
      legalName: input.legalName,
      tradeName: input.tradeName,
      city: input.city,
      country: input.country,
      ibanSet: input.iban != null,
    );
    items.add(s);
    return s;
  }

  @override
  Future<OrganizationSupplier> update(String id, SupplierInput input) async {
    calls.add('update:$id');
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
    updated.add((id, input));
    final i = items.indexWhere((s) => s.id == id);
    final old = items[i];
    final s = OrganizationSupplier(
      id: id,
      code: old.code,
      legalName: input.legalName,
      tradeName: input.tradeName,
      taxNumber: input.taxNumber,
      taxOffice: input.taxOffice,
      contactName: input.contactName,
      email: input.email,
      phone: input.phone,
      address: input.address,
      city: input.city,
      country: input.country,
      specialty: input.specialty,
      notes: input.notes,
      ibanSet: input.iban != null || old.ibanSet,
      isActive: old.isActive,
    );
    items[i] = s;
    return s;
  }

  void _setActive(String id, bool active) {
    final i = items.indexWhere((s) => s.id == id);
    final o = items[i];
    items[i] = OrganizationSupplier(
      id: o.id,
      code: o.code,
      legalName: o.legalName,
      tradeName: o.tradeName,
      taxNumber: o.taxNumber,
      taxOffice: o.taxOffice,
      contactName: o.contactName,
      email: o.email,
      phone: o.phone,
      address: o.address,
      city: o.city,
      country: o.country,
      specialty: o.specialty,
      notes: o.notes,
      ibanSet: o.ibanSet,
      isActive: active,
      createdAt: o.createdAt,
      updatedAt: o.updatedAt,
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

class FakeAuth extends AuthController {
  FakeAuth(this._user);
  final User _user;

  @override
  Future<User?> build() async => _user;
}

/// Gerçek uygulamadaki gibi: `/diger` altında `suppliersRoutes`.
Widget buildSuppliersApp({
  required User user,
  required FakeSuppliersRepository repo,
  String initialLocation = kSuppliersPath,
  ThemeData? theme,
}) {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/diger',
        builder: (_, _) => const Scaffold(body: Center(child: Text('Diğer'))),
        routes: suppliersRoutes,
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(() => FakeAuth(user)),
      suppliersRepositoryProvider.overrideWithValue(repo),
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

/// Golden testleri için uygulama fontları (Inter + MaterialIcons) --
/// aksi halde metin Ahem kutuları olarak çizilir (bkz. dashboard golden).
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

/// Uygulama teması + AppBar başlığı ve düğme etiketlerine Inter. Bu
/// stiller temada fontFamily TAŞIMADIĞI için cihazda platform yazı tipiyle
/// çizilir, test motorunda ise kutu glifine düşer -- ekran görüntüsünde
/// okunabilsinler diye burada Inter verilir (bkz. dashboard_golden_test.dart).
ThemeData goldenTheme() {
  final theme = AppTheme.light();
  const inter = TextStyle(fontFamily: 'Inter');
  final elevated = theme.elevatedButtonTheme.style;
  return theme.copyWith(
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Inter'),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: elevated?.copyWith(
        textStyle: WidgetStatePropertyAll(
          (elevated.textStyle?.resolve(const {}) ?? const TextStyle()).merge(inter),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: (theme.outlinedButtonTheme.style ?? const ButtonStyle()).copyWith(
        textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: (theme.textButtonTheme.style ?? const ButtonStyle()).copyWith(
        textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600)),
      ),
    ),
  );
}
