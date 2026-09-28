import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'employees_paths.dart';
import 'presentation/employee_create_login_screen.dart';
import 'presentation/employee_detail_screen.dart';
import 'presentation/employee_form_screen.dart';
import 'presentation/employees_screen.dart';

export 'employees_paths.dart';

/// "Diğer" dalının (`/diger`) ALT rotaları -- entegrasyon adımı bunları
/// `GoRoute(path: '/diger', routes: [..., ...employeesRoutes])` olarak
/// ekler. Yollar görelidir; tam konumlar için bkz. [EmployeesPaths]. Her
/// ekran kendi izin kapısını (`canAccess`) çağırır.
final List<RouteBase> employeesRoutes = [
  GoRoute(
    path: 'personel',
    builder: (context, state) => const EmployeesScreen(),
    routes: [
      // 'yeni', ':id'den ÖNCE -- aksi halde "yeni" bir personel id'si sanılır.
      GoRoute(path: 'yeni', builder: (context, state) => const EmployeeFormScreen()),
      GoRoute(
        path: ':id',
        // ?uyari=yetki -- kayıt tamamlandı ama kişiye özel yetkiler yazılamadı.
        builder: (context, state) =>
            EmployeeDetailScreen(employeeId: state.pathParameters['id']!, warning: state.uri.queryParameters['uyari']),
        routes: [
          GoRoute(
            path: 'duzenle',
            builder: (context, state) => EmployeeFormScreen(employeeId: state.pathParameters['id']!),
          ),
          GoRoute(
            path: 'giris-hesabi',
            builder: (context, state) => EmployeeCreateLoginScreen(employeeId: state.pathParameters['id']!),
          ),
        ],
      ),
    ],
  ),
];

/// "Diğer" menüsündeki öğe. `permission` KATI `canAccess` ile kontrol
/// edilmeli (bkz. core/auth/permissions.dart): Personel izne bağlıdır,
/// kaba rol şartı yoktur ("Personeli görüntüleme" olan her üye görür,
/// düzenleme izni yoksa salt-okunur çalışır). İkon ana sayfadaki Personel
/// kartıyla (dashboard_registry.dart) aynıdır.
const List<({String label, IconData icon, String route, String permission})> employeesMenuEntries = [
  (label: 'Personel', icon: Icons.engineering_outlined, route: EmployeesPaths.list, permission: 'employees.read'),
];
