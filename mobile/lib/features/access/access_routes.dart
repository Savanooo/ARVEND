import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'access_paths.dart';
import 'presentation/role_detail_screen.dart';
import 'presentation/roles_screen.dart';
import 'presentation/user_detail_screen.dart';
import 'presentation/user_form_screen.dart';
import 'presentation/users_screen.dart';

export 'access_paths.dart';

/// "Diğer" dalının (`/diger`) ALT rotaları -- entegrasyon adımı bunları
/// `GoRoute(path: '/diger', routes: [..., ...accessRoutes])` olarak ekler.
/// Yollar görelidir; tam konumlar için bkz. [AccessPaths]. Her ekran kendi
/// izin kapısını (`canAccess`) çağırır, ayrıca redirect gerekmez.
final List<RouteBase> accessRoutes = [
  GoRoute(
    path: 'kullanicilar',
    builder: (context, state) => const UsersScreen(),
    routes: [
      // 'yeni', ':id'den ÖNCE -- aksi halde "yeni" bir kullanıcı id'si sanılır.
      GoRoute(path: 'yeni', builder: (context, state) => const UserFormScreen()),
      GoRoute(
        path: ':id',
        builder: (context, state) => UserDetailScreen(userId: state.pathParameters['id']!),
      ),
    ],
  ),
  GoRoute(
    path: 'roller',
    builder: (context, state) => const RolesScreen(),
    routes: [
      GoRoute(
        path: ':id',
        builder: (context, state) => RoleDetailScreen(roleId: state.pathParameters['id']!),
      ),
    ],
  ),
];

/// "Diğer" menüsündeki öğeler (Yönetim bölümü). `permission` KATI
/// `canAccess` ile kontrol edilmeli (bkz. core/auth/permissions.dart) --
/// ikisi de Sahip/Yönetici'ye kilitli izinlerdir, kaba rol admin değilse
/// öğe gizlenir.
const List<({String label, IconData icon, String route, String permission})> accessMenuEntries = [
  (
    label: 'Kullanıcılar',
    icon: Icons.manage_accounts_outlined,
    route: AccessPaths.users,
    permission: 'organization.users.read',
  ),
  (
    label: 'Roller & Yetkiler',
    icon: Icons.admin_panel_settings_outlined,
    route: AccessPaths.roles,
    permission: 'organization.roles.read',
  ),
];
