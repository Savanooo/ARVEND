import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_controller.dart';
import '../features/auth/domain/user.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/set_initial_password_screen.dart';
import '../features/calculations/presentation/metraj_screen.dart';
import '../features/customers/presentation/customer_detail_screen.dart';
import '../features/customers/presentation/customers_screen.dart';
import '../features/dashboard/presentation/dashboard_screen.dart';
import '../features/attendance/presentation/attendance_screen.dart';
import '../features/offers/domain/offer.dart';
import '../features/offers/presentation/offer_create_screen.dart';
import '../features/offers/presentation/offer_detail_screen.dart';
import '../features/offers/presentation/offer_revision_detail_screen.dart';
import '../features/offers/presentation/offers_screen.dart';
import '../features/onboarding/presentation/onboarding_wizard_screen.dart';
import '../features/onboarding/presentation/organization_settings_screen.dart';
import '../features/profile/presentation/other_menu_screen.dart';
import '../features/profile/presentation/profile_screen.dart';
import '../features/projects/presentation/project_detail_screen.dart';
import '../features/projects/presentation/projects_screen.dart';
import '../features/projects/domain/procurement.dart';
import '../features/projects/presentation/bid_comparison_screen.dart';
import '../features/projects/presentation/purchase_order_detail_screen.dart';
import '../features/projects/presentation/purchase_order_form_screen.dart';
import '../features/projects/presentation/purchase_request_detail_screen.dart';
import '../features/projects/presentation/purchase_request_form_screen.dart';
import '../features/projects/presentation/progress_claim_detail_screen.dart';
import '../features/projects/presentation/progress_claim_form_screen.dart';
import '../features/projects/presentation/quotation_form_screen.dart';
import '../features/projects/presentation/rfq_detail_screen.dart';
import '../features/projects/presentation/rfq_form_screen.dart';
import '../features/projects/presentation/subcontract_change_order_detail_screen.dart';
import '../features/projects/presentation/subcontract_change_order_form_screen.dart';
import '../features/projects/presentation/subcontract_detail_screen.dart';
import '../features/projects/presentation/subcontract_form_screen.dart';
import '../features/projects/presentation/task_detail_screen.dart';
import '../features/projects/presentation/task_form_screen.dart';
import '../features/tasks/presentation/tasks_screen.dart';
import 'app_shell.dart';

const _passwordSetupRoute = '/sifre-belirle';
const _onboardingRoute = '/kurulum';

/// Kullanıcının BULUNMASI GEREKEN zorunlu rota (varsa) -- yoksa null
/// (serbest gezinme). Sıra: must-change-password ÖNCE, onboarding SONRA
/// (super_admin onboarding'den muaftır, organizasyonu yoktur).
String? _forcedRouteFor(User user) {
  if (user.mustChangePassword) return _passwordSetupRoute;
  if (user.role != UserRole.superAdmin && !user.onboardingCompleted) return _onboardingRoute;
  return null;
}

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
      // go_router BU projede/versiyonda redirect() dönüşlerini otomatik
      // ZİNCİRLEMİYOR (döndürülen her yeni konum için redirect'i tekrar
      // çağırmıyor -- yalnızca TEK bir hop uyguluyor, ampirik olarak
      // doğrulandı: bkz. test/router/route_guards_test.dart). Bu yüzden
      // redirect() burada, mevcut auth durumuna göre DOĞRU NİHAİ konumu
      // TEK seferde hesaplar (ara "/ana-sayfa" durağından geçmeden) --
      // "zaten oradaysa null, değilse doğrudan oraya" deseni.
      //
      // Sıra ÖNEMLİ (spec: must-change-password onboarding'den ÖNCE
      // sıralanır): 1) giriş yapılmış mı, 2) şifre değiştirilmeli mi,
      // 3) onboarding tamamlanmış mı (super_admin bundan muaftır -- hiçbir
      // organizasyona bağlı değildir).
    redirect: (context, state) {
      final authState = ref.read(authControllerProvider);
      final user = authState.valueOrNull;
      final currentLocation = state.matchedLocation;

      if (authState.isLoading) return null;

      if (user == null) {
        return currentLocation == '/giris' ? null : '/giris';
      }

      final forcedRoute = _forcedRouteFor(user);
      if (forcedRoute != null) {
        return currentLocation == forcedRoute ? null : forcedRoute;
      }
      // Zorunlu bir rota yok -- giriş/şifre-belirle/kurulum ekranlarından
      // birindeyse (ör. az önce tamamlandı) ana sayfaya çıkılır; başka bir
      // rotadaysa (serbest gezinme) dokunulmaz.
      const exitRoutes = {'/giris', _passwordSetupRoute, _onboardingRoute};
      if (exitRoutes.contains(currentLocation)) return '/ana-sayfa';
      return null;
    },
    routes: [
      GoRoute(path: '/giris', builder: (context, state) => const LoginScreen()),
      GoRoute(path: _passwordSetupRoute, builder: (context, state) => const SetInitialPasswordScreen()),
      GoRoute(path: _onboardingRoute, builder: (context, state) => const OnboardingWizardScreen()),
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
                  routes: [
                    GoRoute(
                      path: 'gorevler/yeni',
                      builder: (context, state) => TaskFormScreen(projectId: state.pathParameters['id']!),
                    ),
                    GoRoute(
                      path: 'gorevler/:taskId/duzenle',
                      builder: (context, state) => TaskFormScreen(
                        projectId: state.pathParameters['id']!,
                        taskId: state.pathParameters['taskId'],
                      ),
                    ),
                    GoRoute(
                      path: 'gorevler/:taskId',
                      builder: (context, state) => TaskDetailScreen(
                        projectId: state.pathParameters['id']!,
                        taskId: state.pathParameters['taskId']!,
                      ),
                    ),
                    GoRoute(
                      path: 'satin-alma/talepler/yeni',
                      builder: (context, state) =>
                          PurchaseRequestFormScreen(projectId: state.pathParameters['id']!),
                    ),
                    GoRoute(
                      path: 'satin-alma/talepler/:prId/duzenle',
                      builder: (context, state) => PurchaseRequestFormScreen(
                        projectId: state.pathParameters['id']!,
                        prId: state.pathParameters['prId'],
                      ),
                    ),
                    GoRoute(
                      path: 'satin-alma/talepler/:prId',
                      builder: (context, state) => PurchaseRequestDetailScreen(
                        projectId: state.pathParameters['id']!,
                        prId: state.pathParameters['prId']!,
                      ),
                    ),
                    GoRoute(
                      path: 'satin-alma/rfqlar/yeni',
                      builder: (context, state) => RFQFormScreen(projectId: state.pathParameters['id']!),
                    ),
                    GoRoute(
                      path: 'satin-alma/rfqlar/:rfqId/duzenle',
                      builder: (context, state) => RFQFormScreen(
                        projectId: state.pathParameters['id']!,
                        rfqId: state.pathParameters['rfqId'],
                      ),
                    ),
                    GoRoute(
                      path: 'satin-alma/rfqlar/:rfqId/karsilastir',
                      builder: (context, state) => BidComparisonScreen(
                        projectId: state.pathParameters['id']!,
                        rfqId: state.pathParameters['rfqId']!,
                      ),
                    ),
                    GoRoute(
                      path: 'satin-alma/rfqlar/:rfqId/teklifler/yeni',
                      builder: (context, state) => QuotationFormScreen(
                        projectId: state.pathParameters['id']!,
                        rfqId: state.pathParameters['rfqId']!,
                      ),
                    ),
                    GoRoute(
                      path: 'satin-alma/rfqlar/:rfqId/teklifler/:quotationId/duzenle',
                      builder: (context, state) => QuotationFormScreen(
                        projectId: state.pathParameters['id']!,
                        rfqId: state.pathParameters['rfqId']!,
                        quotationId: state.pathParameters['quotationId'],
                      ),
                    ),
                    GoRoute(
                      path: 'satin-alma/rfqlar/:rfqId',
                      builder: (context, state) => RFQDetailScreen(
                        projectId: state.pathParameters['id']!,
                        rfqId: state.pathParameters['rfqId']!,
                      ),
                    ),
                    GoRoute(
                      path: 'satin-alma/siparisler/yeni',
                      builder: (context, state) {
                        final prefill = state.extra
                            as ({
                              String supplierId,
                              String? sourceRfqId,
                              String? sourceQuotationId,
                              List<PurchaseOrderItem> items
                            })?;
                        return PurchaseOrderFormScreen(
                          projectId: state.pathParameters['id']!,
                          prefillSupplierId: prefill?.supplierId,
                          sourceRfqId: prefill?.sourceRfqId,
                          sourceQuotationId: prefill?.sourceQuotationId,
                          prefillItems: prefill?.items ?? const [],
                        );
                      },
                    ),
                    GoRoute(
                      path: 'satin-alma/siparisler/:poId/duzenle',
                      builder: (context, state) => PurchaseOrderFormScreen(
                        projectId: state.pathParameters['id']!,
                        poId: state.pathParameters['poId'],
                      ),
                    ),
                    GoRoute(
                      path: 'satin-alma/siparisler/:poId',
                      builder: (context, state) => PurchaseOrderDetailScreen(
                        projectId: state.pathParameters['id']!,
                        poId: state.pathParameters['poId']!,
                      ),
                    ),
                    GoRoute(
                      path: 'taseronlar/yeni',
                      builder: (context, state) =>
                          SubcontractFormScreen(projectId: state.pathParameters['id']!),
                    ),
                    GoRoute(
                      path: 'taseronlar/:subcontractId/duzenle',
                      builder: (context, state) => SubcontractFormScreen(
                        projectId: state.pathParameters['id']!,
                        subcontractId: state.pathParameters['subcontractId'],
                      ),
                    ),
                    GoRoute(
                      path: 'taseronlar/:subcontractId/hakedisler/yeni',
                      builder: (context, state) => ProgressClaimFormScreen(
                        projectId: state.pathParameters['id']!,
                        subcontractId: state.pathParameters['subcontractId']!,
                      ),
                    ),
                    GoRoute(
                      path: 'taseronlar/:subcontractId/hakedisler/:claimId/duzenle',
                      builder: (context, state) => ProgressClaimFormScreen(
                        projectId: state.pathParameters['id']!,
                        subcontractId: state.pathParameters['subcontractId']!,
                        claimId: state.pathParameters['claimId'],
                      ),
                    ),
                    GoRoute(
                      path: 'taseronlar/:subcontractId/hakedisler/:claimId',
                      builder: (context, state) => ProgressClaimDetailScreen(
                        projectId: state.pathParameters['id']!,
                        subcontractId: state.pathParameters['subcontractId']!,
                        claimId: state.pathParameters['claimId']!,
                      ),
                    ),
                    GoRoute(
                      path: 'taseronlar/:subcontractId/degisiklik-emirleri/yeni',
                      builder: (context, state) => SubcontractChangeOrderFormScreen(
                        projectId: state.pathParameters['id']!,
                        subcontractId: state.pathParameters['subcontractId']!,
                      ),
                    ),
                    GoRoute(
                      path: 'taseronlar/:subcontractId/degisiklik-emirleri/:changeOrderId/duzenle',
                      builder: (context, state) => SubcontractChangeOrderFormScreen(
                        projectId: state.pathParameters['id']!,
                        subcontractId: state.pathParameters['subcontractId']!,
                        changeOrderId: state.pathParameters['changeOrderId'],
                      ),
                    ),
                    GoRoute(
                      path: 'taseronlar/:subcontractId/degisiklik-emirleri/:changeOrderId',
                      builder: (context, state) => SubcontractChangeOrderDetailScreen(
                        projectId: state.pathParameters['id']!,
                        subcontractId: state.pathParameters['subcontractId']!,
                        changeOrderId: state.pathParameters['changeOrderId']!,
                      ),
                    ),
                    GoRoute(
                      path: 'taseronlar/:subcontractId',
                      builder: (context, state) => SubcontractDetailScreen(
                        projectId: state.pathParameters['id']!,
                        subcontractId: state.pathParameters['subcontractId']!,
                      ),
                    ),
                  ],
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
                  builder: (context, state) => OfferCreateScreen(
                    initialCalcItems: state.extra as List<OfferItem>?,
                    initialCustomerId: state.uri.queryParameters['customerId'],
                    initialCustomerName: state.uri.queryParameters['customerName'],
                    initialCustomerPhone: state.uri.queryParameters['customerPhone'],
                    initialCustomerEmail: state.uri.queryParameters['customerEmail'],
                    initialCustomerAddress: state.uri.queryParameters['customerAddress'],
                  ),
                ),
                GoRoute(
                  path: ':id/duzenle',
                  builder: (context, state) =>
                      OfferCreateScreen(offerId: state.pathParameters['id']),
                ),
                GoRoute(
                  path: ':id/revizyonlar/:revisionId',
                  builder: (context, state) => OfferRevisionDetailScreen(
                    offerId: state.pathParameters['id']!,
                    revisionId: state.pathParameters['revisionId']!,
                  ),
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
                GoRoute(
                  path: 'firma-ayarlari',
                  builder: (context, state) => const OrganizationSettingsScreen(),
                ),
              ],
            ),
          ]),
        ],
      ),
    ],
  );
});

