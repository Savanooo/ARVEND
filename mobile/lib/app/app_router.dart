import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_controller.dart';
import '../core/errors/api_exception.dart';
import '../features/access/access_routes.dart';
import '../features/auth/domain/user.dart';
import '../features/auth/presentation/account_access_blocked_screen.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/set_initial_password_screen.dart';
import '../features/auth/presentation/super_admin_unsupported_screen.dart';
import '../features/calc_admin/calc_admin_routes.dart';
import '../features/calculations/presentation/metraj_screen.dart';
import '../features/cost_codes/cost_codes_routes.dart';
import '../features/customers/presentation/customer_detail_screen.dart';
import '../features/customers/presentation/customers_screen.dart';
import '../features/dashboard/presentation/attention_screen.dart';
import '../features/dashboard/presentation/dashboard_screen.dart';
import '../features/attendance/presentation/attendance_screen.dart';
import '../features/employees/employees_routes.dart';
import '../features/offers/domain/offer.dart';
import '../features/offers/presentation/offer_create_screen.dart';
import '../features/offers/presentation/offer_detail_screen.dart';
import '../features/offers/presentation/offer_revision_detail_screen.dart';
import '../features/offers/presentation/offers_screen.dart';
import '../features/onboarding/presentation/onboarding_wizard_screen.dart';
import '../features/onboarding/presentation/organization_settings_screen.dart';
import '../features/notifications/presentation/notifications_screen.dart';
import '../features/profile/presentation/about_screen.dart';
import '../features/profile/presentation/other_menu_screen.dart';
import '../features/products/products_routes.dart';
import '../features/profile/presentation/profile_screen.dart';
import '../features/projects/presentation/project_detail_screen.dart';
import '../features/projects/projects_routes.dart';
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
import '../features/settings/settings_routes.dart';
import '../features/suppliers/suppliers_routes.dart';
import '../features/tasks/presentation/tasks_screen.dart';
import 'app_shell.dart';

const _passwordSetupRoute = '/sifre-belirle';
const _onboardingRoute = '/kurulum';
const _superAdminUnsupportedRoute = '/hesap-yonetim-web';
const _accountBlockedRoute = '/hesap-erisimi-kapali';

/// Kullanıcının BULUNMASI GEREKEN zorunlu rota (varsa) -- yoksa null
/// (serbest gezinme). Sıra: super_admin ÖNCE (organizasyonu YOKTUR, bu
/// yüzden aşağıdaki iki kiracı-özel kontrolden HİÇBİRİNE asla girmemeli --
/// ARVEND Mobile TAMAMEN bir kiracı uygulamasıdır, bkz. dosya başı yorumu),
/// SONRA must-change-password, SONRA onboarding.
String? _forcedRouteFor(User user) {
  if (user.role == UserRole.superAdmin) return _superAdminUnsupportedRoute;
  if (user.mustChangePassword) return _passwordSetupRoute;
  if (!user.onboardingCompleted) return _onboardingRoute;
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
      // Sıra ÖNEMLİ: 1) giriş yapılmış mı (değilse -- organizasyon engeli
      // yüzünden mi düşürüldü, bkz. aşağıdaki blok), 2) super_admin mi
      // (bkz. _forcedRouteFor -- kiracı akışlarının TAMAMINDAN muaf, mobilde
      // hiçbir organizasyona bağlı değildir), 3) şifre değiştirilmeli mi,
      // 4) onboarding tamamlanmış mı.
    redirect: (context, state) {
      final authState = ref.read(authControllerProvider);
      final user = authState.valueOrNull;
      final currentLocation = state.matchedLocation;

      if (authState.isLoading) return null;

      if (user == null) {
        // Organizasyon askıya alınmış/iptal edilmiş/silinmiş olduğu için
        // oturum az önce ApiClient tarafından düşürüldüyse (bkz.
        // accountAccessIssueProvider, main.dart onAccountAccessBlocked)
        // düz /giris yerine bunu açıklayan özel ekrana gidilir; diğer TÜM
        // durumlarda (sıradan çıkış/süresi dolma/kullanıcı engeli -- bu
        // sonuncusu LoginScreen'de bilgilendirici bir mesajla ele alınır)
        // /giris'e düşülür.
        final blockedRoute =
            ref.read(accountAccessIssueProvider) == AccountAccessIssue.organizationBlocked
                ? _accountBlockedRoute
                : '/giris';
        return currentLocation == blockedRoute ? null : blockedRoute;
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
      GoRoute(
        path: _superAdminUnsupportedRoute,
        builder: (context, state) => const SuperAdminUnsupportedScreen(),
      ),
      GoRoute(
        path: _accountBlockedRoute,
        builder: (context, state) => const AccountAccessBlockedScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/ana-sayfa',
              builder: (context, state) => const DashboardScreen(),
              routes: [
                // Ana sayfanın "Dikkat Gerektirenler" tam listesi; ?kod= ile
                // gelen grup açık başlar (spec §6.4).
                GoRoute(
                  path: 'dikkat',
                  builder: (context, state) => AttentionScreen(initialCode: state.uri.queryParameters['kod']),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/projeler',
              // ?status=completed -- ana sayfanın "Tamamlananlar" bağlantısı.
              builder: (context, state) => ProjectsScreen(initialStatus: state.uri.queryParameters['status']),
              routes: [
                GoRoute(
                  path: ':id',
                  // ?grup=ozet|finans|operasyon|dokumanlar&alt=<alt görünüm> --
                  // ana sayfa derin bağlantıları (spec D4, bkz. mobileRouteFor).
                  builder: (context, state) => ProjectDetailScreen(
                    projectId: state.pathParameters['id']!,
                    initialGroup: state.uri.queryParameters['grup'],
                    initialView: state.uri.queryParameters['alt'],
                  ),
                  routes: [
                    // /projeler/:id/duzenle -- proje bilgilerini düzenle
                    // (projects.update; ekran izni kendisi de denetler).
                    ...projectEditRoutes,
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
                GoRoute(path: 'bildirimler', builder: (context, state) => const NotificationsScreen()),
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
                GoRoute(path: 'hakkinda', builder: (context, state) => const AboutScreen()),
                // Yönetim modülleri (web /admin/** karşılıkları). Yollar her
                // modülün kendi *_routes.dart dosyasında, göreli tanımlıdır;
                // hepsi "Diğer" dalında push ile açılır. Rota düzeyinde
                // guard YOK: her ekran veri çekmeden önce kendi iznini katı
                // `canAccess` ile denetler (izinsizse açıklama gösterir).
                ...productsRoutes, // urunler, urunler/{yeni,kaynaklar,zamlar,:id,:id/duzenle}
                ...employeesRoutes, // personel, personel/{yeni,:id,:id/duzenle,:id/giris-hesabi}
                ...accessRoutes, // kullanicilar, kullanicilar/{yeni,:id}, roller, roller/:id
                ...suppliersRoutes, // tedarikciler, tedarikciler/:id
                ...costCodesRoutes, // maliyet-kodlari, maliyet-kodlari/:id
                ...calcAdminRoutes, // metraj-receteleri, …/:groupId, …/:groupId/:categoryId
                ...settingsRoutes, // eposta-ayarlari
              ],
            ),
          ]),
        ],
      ),
    ],
  );
});

