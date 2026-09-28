import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'presentation/calc_category_detail_screen.dart';
import 'presentation/calc_group_detail_screen.dart';
import 'presentation/calc_groups_screen.dart';

/// Metraj reçeteleri rotaları -- `/diger` dalının ALTINA (relative path)
/// eklenir, tam yollar:
///   /diger/metraj-receteleri                         -> Gruplar
///   /diger/metraj-receteleri/:groupId                -> Grup + kategoriler
///   /diger/metraj-receteleri/:groupId/:categoryId    -> Kategori + reçete
/// Reçete kalemi formu ayrı bir rota değildir; kategori ekranından
/// `Navigator.push` ile açılır (kalem nesnesi doğrudan geçirilir).
///
/// Ekranların kendileri de izin kontrolü yapar (fail-closed `canAccess`),
/// yani menüde gizli olsa bile derin bağlantıyla gelen yetkisiz kullanıcı
/// veri çekmeden anlaşılır bir mesaj görür.
final List<RouteBase> calcAdminRoutes = [
  GoRoute(
    path: 'metraj-receteleri',
    builder: (context, state) => const CalcGroupsScreen(),
    routes: [
      GoRoute(
        path: ':groupId',
        builder: (context, state) => CalcGroupDetailScreen(groupId: state.pathParameters['groupId']!),
        routes: [
          GoRoute(
            path: ':categoryId',
            builder: (context, state) => CalcCategoryDetailScreen(
              groupId: state.pathParameters['groupId']!,
              categoryId: state.pathParameters['categoryId']!,
            ),
          ),
        ],
      ),
    ],
  ),
];

/// Diğer menüsü girdisi (label, icon, route, permission). `permission`
/// katı `canAccess` ile kontrol edilmeli (bkz. core/auth/permissions.dart).
/// Menüde "Yönetim" bölümüne aittir. İkon: reçete kitabı (uygulamada
/// receipt_long masraf/hakediş anlamında kullanılır).
const calcAdminMenuEntries = <({String label, IconData icon, String route, String permission})>[
  (
    label: 'Metraj Reçeteleri',
    icon: Icons.menu_book_outlined,
    route: '/diger/metraj-receteleri',
    permission: 'calculations.read',
  ),
];
