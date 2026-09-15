import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_controller.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/calculations/presentation/metraj_screen.dart';
import '../features/customers/presentation/customer_detail_screen.dart';
import '../features/customers/presentation/customers_screen.dart';
import '../features/dashboard/presentation/dashboard_screen.dart';
import '../features/attendance/presentation/attendance_screen.dart';
import '../features/offers/domain/offer.dart';
import '../features/offers/presentation/offer_create_screen.dart';
import '../features/offers/presentation/offer_detail_screen.dart';
import '../features/offers/presentation/offers_screen.dart';
import '../features/profile/presentation/other_menu_screen.dart';
import '../features/profile/presentation/profile_screen.dart';
import '../features/projects/presentation/project_detail_screen.dart';
import '../features/projects/presentation/projects_screen.dart';
import '../features/tasks/presentation/tasks_screen.dart';
import 'app_shell.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

/// Auth durumu değiştikçe redirect mantığının yeniden çalışması için
/// go_router'a bir `Listenable` verilir (`GoRouterRefreshStream` yerine
/// ValueNotifier ile basit bir köprü - AuthController AsyncNotifier zaten
/// Riverpod tarafında dinleniyor, burada yalnız router'ı "refresh et" demek
/// yeterli).
class _RouterRefreshNotifier extends ChangeNotifier {
  _RouterRefreshNotifier(Ref ref) {
    ref.listen(authControllerProvider, (_, _) => notifyListeners());
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefreshNotifier(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/giris',
    refreshListenable: refresh,
    redirect: (context, state) {
      final authState = ref.read(authControllerProvider);
      final isLoggedIn = authState.valueOrNull != null;
      final isLoggingIn = state.matchedLocation == '/giris';

      if (authState.isLoading) return null;
      if (!isLoggedIn && !isLoggingIn) return '/giris';
      if (isLoggedIn && isLoggingIn) return '/ana-sayfa';
      return null;
    },
    routes: [
      GoRoute(path: '/giris', builder: (context, state) => const LoginScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(path: '/ana-sayfa', builder: (context, state) => const DashboardScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/projeler',
              builder: (context, state) => const ProjectsScreen(),
              routes: [
                GoRoute(
                  path: ':id',
                  builder: (context, state) => ProjectDetailScreen(projectId: state.pathParameters['id']!),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/teklifler',
              builder: (context, state) => const OffersScreen(),
              routes: [
                GoRoute(
                  path: 'yeni',
                  builder: (context, state) =>
                      OfferCreateScreen(initialCalcItems: state.extra as List<OfferItem>?),
                ),
                GoRoute(
                  path: ':id',
                  builder: (context, state) => OfferDetailScreen(offerId: state.pathParameters['id']!),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(path: '/gorevler', builder: (context, state) => const TasksScreen()),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/diger',
              builder: (context, state) => const OtherMenuScreen(),
              routes: [
                GoRoute(path: 'metraj', builder: (context, state) => const MetrajScreen()),
                GoRoute(
                  path: 'musteriler',
                  builder: (context, state) => const CustomersScreen(),
                  routes: [
                    GoRoute(
                      path: ':id',
                      builder: (context, state) =>
                          CustomerDetailScreen(customerId: state.pathParameters['id']!),
                    ),
                  ],
                ),
                GoRoute(path: 'mesai', builder: (context, state) => const AttendanceScreen()),
                GoRoute(path: 'profil', builder: (context, state) => const ProfileScreen()),
              ],
            ),
          ]),
        ],
      ),
    ],
  );
});
