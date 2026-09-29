import '../../../core/config/app_config.dart';

/// Sözleşme + Ek İşler izin kodları (backend domain.PermProjects*,
/// migration 0034/0036). Hepsi PROJE kapsamlıdır: backend `projPerm` ile
/// izin + proje üyeliğini birlikte denetler; uygulamadaki kontrol yalnızca
/// UX'tir (proje detayındaki `_failOpen` / `UserCan.can` ile aynı karar).
const kContractsReadPermission = 'projects.contracts.read';
const kContractsManagePermission = 'projects.contracts.manage';
const kContractsLifecyclePermission = 'projects.contracts.lifecycle';

/// Ek işlerin KENDİ izni yok -- finans izinleri altında yaşar.
const kChangeOrdersReadPermission = 'projects.finance.read';
const kChangeOrdersManagePermission = 'projects.finance.manage';

/// Tam yollar -- tümü `/projeler/:id` rotasının ALTINDA (bkz.
/// contract_co_routes.dart).
String projectContractPath(String projectId) => '/projeler/$projectId/sozlesme';
String projectContractEditPath(String projectId) => '/projeler/$projectId/sozlesme/duzenle';
String projectChangeOrdersPath(String projectId) => '/projeler/$projectId/ek-isler';
String projectChangeOrderNewPath(String projectId) => '/projeler/$projectId/ek-isler/yeni';
String projectChangeOrderPath(String projectId, String changeOrderId) =>
    '/projeler/$projectId/ek-isler/$changeOrderId';
String projectChangeOrderEditPath(String projectId, String changeOrderId) =>
    '/projeler/$projectId/ek-isler/$changeOrderId/duzenle';

/// Müşterinin ek işi görüp onaylayıp/reddettiği sayfa -- web
/// `app/ek-is/[token]` (backend e-postasına eklenen `frontendURL + /ek-is/`
/// ile aynı). Web ve API aynı alan adında yayında (teklif paylaşım linki
/// `/paylas/{token}` ile aynı ilke, bkz. offer_detail_screen.dart).
String changeOrderShareUrl(String token) => '${AppConfig.apiBaseUrl}/ek-is/$token';
