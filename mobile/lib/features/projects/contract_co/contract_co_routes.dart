import 'package:go_router/go_router.dart';

import 'presentation/change_order_detail_screen.dart';
import 'presentation/change_order_form_screen.dart';
import 'presentation/change_orders_view.dart';
import 'presentation/contract_form_screen.dart';
import 'presentation/contract_view.dart';

export 'contract_co_paths.dart';
export 'contract_co_sections.dart';

/// Sözleşme + Ek İşler rotaları -- `/projeler/:id` GoRoute'unun `routes:`
/// listesine `...contractCoRoutes` ile eklenir (projectEditRoutes gibi).
/// Yollar GÖRELİDİR ve mevcut satın alma/taşeron rotalarıyla aynı düz
/// (kardeş) düzendedir; derin bağlantıda geri tuşu proje detayına döner:
///
/// - `sozlesme`               -> `/projeler/:id/sozlesme`               Sözleşme
/// - `sozlesme/duzenle`       -> `/projeler/:id/sozlesme/duzenle`       Şartları düzenle (taslak)
/// - `ek-isler`               -> `/projeler/:id/ek-isler`               Ek İşler listesi
/// - `ek-isler/yeni`          -> `/projeler/:id/ek-isler/yeni`          Yeni Ek İş
/// - `ek-isler/:coId`         -> `/projeler/:id/ek-isler/:coId`         Ek İş detayı
/// - `ek-isler/:coId/duzenle` -> `/projeler/:id/ek-isler/:coId/duzenle` Ek İşi düzenle (taslak)
///
/// `ek-isler/yeni`, `ek-isler/:coId`'den ÖNCE gelmeli (ilk eşleşen kazanır).
/// Ekranlar izni KENDİLERİ denetler (izin yoksa API çağırmadan "yetkin
/// yok"); rota düzeyinde ek guard gerekmez.
final List<RouteBase> contractCoRoutes = [
  GoRoute(
    path: 'sozlesme',
    builder: (context, state) => ProjectContractScreen(projectId: state.pathParameters['id']!),
  ),
  GoRoute(
    path: 'sozlesme/duzenle',
    builder: (context, state) => ContractFormScreen(projectId: state.pathParameters['id']!),
  ),
  GoRoute(
    path: 'ek-isler',
    builder: (context, state) => ProjectChangeOrdersScreen(projectId: state.pathParameters['id']!),
  ),
  GoRoute(
    path: 'ek-isler/yeni',
    builder: (context, state) => ChangeOrderFormScreen(projectId: state.pathParameters['id']!),
  ),
  GoRoute(
    path: 'ek-isler/:coId/duzenle',
    builder: (context, state) => ChangeOrderFormScreen(
      projectId: state.pathParameters['id']!,
      changeOrderId: state.pathParameters['coId'],
    ),
  ),
  GoRoute(
    path: 'ek-isler/:coId',
    builder: (context, state) => ChangeOrderDetailScreen(
      projectId: state.pathParameters['id']!,
      changeOrderId: state.pathParameters['coId']!,
    ),
  ),
];
