import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/permissions.dart';
import '../../auth/domain/user.dart';
import 'finance_plan_paths.dart';
import 'presentation/invoice_detail_screen.dart';
import 'presentation/invoice_form_screen.dart';
import 'presentation/invoices_tab.dart';
import 'presentation/payment_plan_item_detail_screen.dart';
import 'presentation/payment_plan_item_form_screen.dart';
import 'presentation/payment_plan_tab.dart';

export 'finance_plan_paths.dart';
export 'presentation/invoices_tab.dart' show InvoicesTab;
export 'presentation/payment_plan_tab.dart' show PaymentPlanTab;

/// Proje detay rotasının (`/projeler/:id`) `routes:` listesine eklenecek
/// ALT rotalar -- yollar GÖRELİDİR (`odeme-plani` -> `/projeler/:id/odeme-plani`).
/// Kayıt: app_router.dart'ta `/projeler/:id` GoRoute'unun `routes:` listesine
/// `...financePlanRoutes`. Proje kimliği üst rotanın `:id` parametresidir.
/// `yeni` literal yolu `:itemId`/`:invoiceId`'den ÖNCE tanımlıdır (go_router
/// sırayla eşleştirir). Ekranlar izni KENDİLERİ denetler (okuma izni yoksa
/// API çağırmadan "yetkin yok" gösterir; 403 gelirse çökmez).
final List<RouteBase> financePlanRoutes = [
  GoRoute(
    path: kPaymentPlanAlt,
    builder: (context, state) => PaymentPlanScreen(projectId: state.pathParameters['id']!),
    routes: [
      GoRoute(
        path: 'yeni',
        builder: (context, state) => PaymentPlanItemFormScreen(projectId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: ':itemId',
        builder: (context, state) => PaymentPlanItemDetailScreen(
          projectId: state.pathParameters['id']!,
          itemId: state.pathParameters['itemId']!,
        ),
        routes: [
          GoRoute(
            path: 'duzenle',
            builder: (context, state) => PaymentPlanItemFormScreen(
              projectId: state.pathParameters['id']!,
              itemId: state.pathParameters['itemId']!,
            ),
          ),
        ],
      ),
    ],
  ),
  GoRoute(
    path: kInvoicesAlt,
    builder: (context, state) => InvoicesScreen(projectId: state.pathParameters['id']!),
    routes: [
      GoRoute(
        path: 'yeni',
        builder: (context, state) => InvoiceFormScreen(projectId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: ':invoiceId',
        builder: (context, state) => InvoiceDetailScreen(
          projectId: state.pathParameters['id']!,
          invoiceId: state.pathParameters['invoiceId']!,
        ),
      ),
    ],
  ),
];

/// Proje detayına eklenecek bir alt görünümün tanımı (entegrasyon adımı
/// için). [group]/[alt] derin bağlantı değerleridir (`?grup=finans&alt=...`).
/// [tabBuilder] Finans grubunun çip şeridinin altındaki gövdeye (Expanded
/// içinde, kendi kaydırmalı listesi + RefreshIndicator'ı ile) konur.
/// Görünürlük [visibleFor] ile (proje
/// detayındaki fail-open `_failOpen` ile aynı `can` deseni); yazma
/// aksiyonlarını ekranlar [managePermission] ile kendileri gizler.
@immutable
class FinancePlanView {
  const FinancePlanView({
    required this.group,
    required this.alt,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.readPermission,
    required this.managePermission,
    required this.routeFor,
    required this.tabBuilder,
  });

  /// `?grup=` değeri (`finans`).
  final String group;

  /// `?alt=` değeri (`odeme-plani` | `faturalar`).
  final String alt;

  /// Segment/başlık etiketi (web ile aynı Türkçe).
  final String label;

  /// Özet ekranındaki gezinme kartı alt metni gibi yerler için kısa açıklama.
  final String subtitle;
  final IconData icon;
  final String readPermission;
  final String managePermission;

  /// Tam ekran liste rotası.
  final String Function(String projectId) routeFor;
  final Widget Function(String projectId) tabBuilder;

  bool visibleFor(User? user) => user.can(readPermission);
}

/// Finans grubuna eklenecek iki alt görünüm: Ödeme Planı ve Faturalar.
final List<FinancePlanView> financePlanViews = [
  FinancePlanView(
    group: kFinancePlanGroup,
    alt: kPaymentPlanAlt,
    label: 'Ödeme Planı',
    subtitle: 'Vadeler, tahsil edilen ve kalan tutarlar',
    icon: Icons.event_note_outlined,
    readPermission: kFinancePlanReadPermission,
    managePermission: kFinancePlanManagePermission,
    routeFor: paymentPlanPath,
    tabBuilder: (projectId) => PaymentPlanTab(projectId: projectId),
  ),
  FinancePlanView(
    group: kFinancePlanGroup,
    alt: kInvoicesAlt,
    label: 'Faturalar',
    subtitle: 'Satış ve alış faturaları, durumları',
    icon: Icons.receipt_long_outlined,
    readPermission: kFinancePlanReadPermission,
    managePermission: kFinancePlanManagePermission,
    routeFor: invoicesPath,
    tabBuilder: (projectId) => InvoicesTab(projectId: projectId),
  ),
];
