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
import 'package:arvend/features/calc_admin/calc_admin_routes.dart';
import 'package:arvend/features/calc_admin/data/calc_admin_providers.dart';
import 'package:arvend/features/calc_admin/data/calc_admin_repository.dart';
import 'package:arvend/features/calc_admin/domain/calc_admin.dart';

import '../dashboard/fixtures.dart' show kAllPermissions;

/// Ağsız sahte depo -- ekran testleri ve golden'lar bunu kullanır.
class FakeCalcAdminRepository implements CalcAdminRepository {
  FakeCalcAdminRepository({
    List<CalcAdminGroup>? groups,
    Map<String, List<CalcAdminCategory>>? categories,
    Map<String, List<CalcRecipeItem>>? items,
    List<CalcProductOption>? products,
  })  : groupsData = groups ?? sampleGroups(),
        categoriesData = categories ?? sampleCategories(),
        itemsData = items ?? sampleItems(),
        productsData = products ?? sampleProducts();

  List<CalcAdminGroup> groupsData;
  Map<String, List<CalcAdminCategory>> categoriesData;
  Map<String, List<CalcRecipeItem>> itemsData;
  List<CalcProductOption> productsData;

  /// Verilirse ilgili okuma bu hatayı fırlatır (ör. 403).
  Object? groupsError;
  Object? writeError;

  /// Verilirse yazma/silme çağrıları bu tamamlanana kadar bekler (kayıt
  /// sürerken ekranın davranışını denemek için).
  Completer<void>? writeGate;

  /// Verilirse grup listesi okuması bu tamamlanana kadar bekler.
  Completer<void>? groupsGate;

  final calls = <String>[];
  final createdGroups = <({String name, String slug, String description})>[];
  final createdCategories = <({String groupId, String name, String slug, String description})>[];
  final itemInputs = <({String? id, CalcRecipeItemInput input})>[];
  final deletedItemIds = <String>[];

  @override
  Future<List<CalcAdminGroup>> groups() async {
    calls.add('groups');
    if (groupsGate != null) await groupsGate!.future;
    if (groupsError != null) throw groupsError!;
    return groupsData;
  }

  @override
  Future<CalcAdminGroup> createGroup({required String name, required String slug, required String description}) async {
    calls.add('createGroup');
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
    createdGroups.add((name: name, slug: slug, description: description));
    final g = CalcAdminGroup(
        id: 'g-new', slug: slug, name: name, description: description, sortOrder: 0, isActive: true);
    groupsData = [...groupsData, g];
    return g;
  }

  @override
  Future<CalcAdminGroup> updateGroup(
    String id, {
    required String name,
    required String slug,
    required String description,
    required int sortOrder,
    required bool isActive,
  }) async {
    calls.add('updateGroup:$id');
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
    final g = CalcAdminGroup(
        id: id, slug: slug, name: name, description: description, sortOrder: sortOrder, isActive: isActive);
    groupsData = [for (final x in groupsData) x.id == id ? g : x];
    return g;
  }

  @override
  Future<List<CalcAdminCategory>> categories(String groupId) async {
    calls.add('categories:$groupId');
    return categoriesData[groupId] ?? const [];
  }

  @override
  Future<CalcAdminCategory> createCategory({
    required String groupId,
    required String name,
    required String slug,
    required String description,
  }) async {
    calls.add('createCategory');
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
    createdCategories.add((groupId: groupId, name: name, slug: slug, description: description));
    final c = CalcAdminCategory(
      id: 'c-new',
      groupId: groupId,
      slug: slug,
      name: name,
      description: description,
      imageFileId: null,
      sortOrder: 0,
      isActive: true,
    );
    categoriesData = {
      ...categoriesData,
      groupId: [...?categoriesData[groupId], c],
    };
    return c;
  }

  @override
  Future<CalcAdminCategory> updateCategory(
    CalcAdminCategory existing, {
    required String name,
    required String slug,
    required String description,
    required int sortOrder,
    required bool isActive,
  }) async {
    calls.add('updateCategory:${existing.id}');
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
    return existing;
  }

  @override
  Future<List<CalcRecipeItem>> recipeItems(String categoryId) async {
    calls.add('items:$categoryId');
    return itemsData[categoryId] ?? const [];
  }

  @override
  Future<CalcRecipeItem> createRecipeItem(CalcRecipeItemInput input) async {
    calls.add('createItem');
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
    itemInputs.add((id: null, input: input));
    return CalcRecipeItem.fromJson({'id': 'i-new', ...input.toJson()});
  }

  @override
  Future<CalcRecipeItem> updateRecipeItem(String id, CalcRecipeItemInput input) async {
    calls.add('updateItem:$id');
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
    itemInputs.add((id: id, input: input));
    return CalcRecipeItem.fromJson({'id': id, ...input.toJson()});
  }

  @override
  Future<void> deleteRecipeItem(String id) async {
    calls.add('deleteItem:$id');
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
    deletedItemIds.add(id);
    itemsData = {
      for (final e in itemsData.entries) e.key: [for (final i in e.value) if (i.id != id) i],
    };
  }

  @override
  Future<List<CalcProductOption>> allProducts() async {
    calls.add('products');
    return productsData;
  }
}

const kForbidden = ApiException(statusCode: 403, message: 'bu işlem için yetkiniz yok', kind: ApiErrorKind.forbidden);

List<CalcAdminGroup> sampleGroups() => const [
      CalcAdminGroup(
        id: 'g1',
        slug: 'petek-tavanlar',
        name: 'Petek Tavanlar',
        description: 'Alüminyum petek ve karo tavan sistemleri',
        sortOrder: 1,
        isActive: true,
      ),
      CalcAdminGroup(
        id: 'g2',
        slug: 'alcipan-sistemleri',
        name: 'Alçıpan Sistemleri',
        description: '',
        sortOrder: 2,
        isActive: true,
      ),
      CalcAdminGroup(
        id: 'g3',
        slug: 'cati-kaplamalari',
        name: 'Çatı Kaplamaları',
        description: '',
        sortOrder: 3,
        isActive: true,
      ),
    ];

Map<String, List<CalcAdminCategory>> sampleCategories() => {
      'g1': const [
        CalcAdminCategory(
          id: 'c1',
          groupId: 'g1',
          slug: '10x10-petek-tavan',
          name: '10x10 Petek Tavan',
          description: 'Standart 10x10 cm hücreli petek tavan',
          imageFileId: 'img-1',
          sortOrder: 1,
          isActive: true,
        ),
        CalcAdminCategory(
          id: 'c2',
          groupId: 'g1',
          slug: '15x15-petek-tavan',
          name: '15x15 Petek Tavan',
          description: '',
          imageFileId: null,
          sortOrder: 2,
          isActive: true,
        ),
      ],
    };

CalcRecipeItem _item({
  required String id,
  required String name,
  required String unit,
  String type = CalcType.areaBased,
  String perM2 = '0',
  String perMeter = '0',
  String fixed = '0',
  String waste = '0',
  String rounding = CalcRounding.none,
  String? productId,
  String? packageSize,
  String groupName = '',
  bool active = true,
  int sort = 0,
}) =>
    CalcRecipeItem(
      id: id,
      categoryId: 'c1',
      productId: productId,
      materialName: name,
      unit: unit,
      calculationType: type,
      quantityPerM2: perM2,
      quantityPerMeter: perMeter,
      fixedQuantity: fixed,
      wastePercent: waste,
      roundingType: rounding,
      minQuantity: null,
      packageSize: packageSize,
      referenceUnitPrice: '185.50',
      groupName: groupName,
      sortOrder: sort,
      isActive: active,
      notes: null,
    );

Map<String, List<CalcRecipeItem>> sampleItems() => {
      'c1': [
        _item(
          id: 'i1',
          name: 'Petek Panel 10x10',
          unit: 'm²',
          perM2: '1.000000',
          waste: '5',
          rounding: CalcRounding.ceil,
          productId: 'p1',
          groupName: 'Ana Malzemeler',
        ),
        _item(
          id: 'i2',
          name: 'Kenar Profili',
          unit: 'm',
          type: CalcType.perimeterBased,
          perMeter: '1.050000',
          waste: '3',
          productId: 'p2',
          groupName: 'Ana Malzemeler',
        ),
        _item(
          id: 'i3',
          name: 'Askı Teli',
          unit: 'paket',
          perM2: '0.250000',
          packageSize: '100',
          rounding: CalcRounding.ceil,
          groupName: 'Bağlantı',
        ),
        _item(
          id: 'i4',
          name: 'Montaj Seti',
          unit: 'adet',
          type: CalcType.fixed,
          fixed: '1',
          productId: 'p-missing',
          active: false,
        ),
      ],
    };

List<CalcProductOption> sampleProducts() => const [
      CalcProductOption(id: 'p1', name: 'Alüminyum Petek Panel 10x10', unit: 'm²', unitPrice: 420.0),
      CalcProductOption(id: 'p2', name: 'L Kenar Profili 3m', unit: 'm', unitPrice: 38.5),
      CalcProductOption(id: 'p3', name: 'Askı Teli Paketi', unit: 'paket', unitPrice: 95.0),
    ];

User calcUser({required UserRole role, required Iterable<String> permissions}) => User(
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

/// Sahip: tüm izinler.
final ownerUser = calcUser(role: UserRole.admin, permissions: kAllPermissions);

/// Yalnızca görüntüleme (ürün kataloğu izni YOK).
final calcReaderUser = calcUser(role: UserRole.kullanici, permissions: const ['calculations.read']);

/// Metraj düzenleyebilir ama ürün kataloğunu göremez.
final calcManagerNoProductsUser =
    calcUser(role: UserRole.kullanici, permissions: const ['calculations.read', 'calculations.manage']);

/// Hiçbir metraj izni yok.
final noCalcUser = calcUser(role: UserRole.kullanici, permissions: const ['projects.read']);

class FakeAuthController extends AuthController {
  FakeAuthController(this._user);
  final User? _user;

  @override
  Future<User?> build() async => _user;
}

/// Uygulama teması; AppBar başlığı ve dolu buton metni Inter (bkz.
/// dashboard golden testi): temadaki bu iki stil fontFamily taşımadığı için
/// cihazda platform yazı tipiyle çizilir, test motorunda ise kutu glifine
/// düşerdi.
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

/// Golden'larda gölgeler gerçek hâliyle çizilsin (flutter_test varsayılanı
/// gölgeleri siyah kenar olarak çizer). Test SONUNDA geri alınmalı --
/// çerçeve, gövde bittikten sonra bu değişkenin varsayılanda olduğunu denetler.
Future<void> withRealShadows(Future<void> Function() body) async {
  debugDisableShadows = false;
  try {
    await body();
  } finally {
    debugDisableShadows = true;
  }
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

/// `/diger` dalını taklit eden yönlendirici + `calcAdminRoutes`.
Widget calcAdminApp({
  required User? user,
  required FakeCalcAdminRepository repo,
  String location = '/diger/metraj-receteleri',
}) {
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/diger',
        builder: (_, _) => const Scaffold(body: Center(child: Text('Diğer'))),
        routes: calcAdminRoutes,
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(() => FakeAuthController(user)),
      calcAdminRepositoryProvider.overrideWithValue(repo),
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

/// Navigator ile açılan tek bir ekranı (kalem formu gibi) uygulamadaki
/// gibi bir üst sayfanın ÜSTÜNE itilmiş hâliyle çizer: üst çubukta geri oku
/// (yeni kalemde tam ekran diyalog kapatma "X"i) görünür ve `pop(true)`
/// alttaki sayfaya döner.
Widget calcAdminScreen({
  required User? user,
  required FakeCalcAdminRepository repo,
  required Widget child,
  bool fullscreenDialog = false,
}) {
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(() => FakeAuthController(user)),
      calcAdminRepositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: goldenTheme(),
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => const Scaffold(body: Center(child: Text('Kategori')))),
      onGenerateInitialRoutes: (_) => [
        MaterialPageRoute(builder: (_) => const Scaffold(body: Center(child: Text('Kategori')))),
        MaterialPageRoute(fullscreenDialog: fullscreenDialog, builder: (_) => child),
      ],
    ),
  );
}
