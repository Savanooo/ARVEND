import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/finance_plan/data/finance_plan_providers.dart';
import 'package:arvend/features/projects/finance_plan/data/finance_plan_repository.dart';
import 'package:arvend/features/projects/finance_plan/domain/payment_plan.dart';
import 'package:arvend/features/projects/finance_plan/domain/project_invoice.dart';
import 'package:arvend/features/projects/finance_plan/finance_plan_routes.dart';

import '../dashboard/fixtures.dart' show kAllPermissions;
import '../suppliers/suppliers_test_support.dart' show FakeAuth, buildUser;

export '../suppliers/suppliers_test_support.dart' show goldenTheme, loadAppFonts, forbidden;

/// Ödeme planı / fatura testlerinin ortak kurulumu: sahte depo (ağ YOK),
/// persona kullanıcıları, sabit "bugün" (2026-09-29, deterministik vade
/// ipuçları) ve gerçek rota ağacı (`financePlanRoutes`, `/projeler/:id`
/// altında). Kullanıcı/font/tema yardımcıları tedarikçi testleriyle ortak.

/// Testlerin "bugün"ü (İstanbul günü).
final kFinanceToday = DateTime.utc(2026, 9, 29);

const kProjectId = 'p1';

/// Sahip: kaba rol admin + tüm izinler.
final fpOwnerUser = buildUser(
  id: 'owner',
  role: UserRole.admin,
  roleCode: 'owner',
  permissions: kAllPermissions.toSet(),
);

/// Finans rolü: proje finansını görüntüler ve yönetir.
final fpManagerUser = buildUser(
  id: 'finance',
  roleCode: 'finance',
  permissions: {'projects.read', kFinancePlanReadPermission, kFinancePlanManagePermission},
);

/// Yalnızca görüntüleme (ör. finansı görebilen Proje Yöneticisi).
final fpReadOnlyUser = buildUser(
  id: 'pm',
  roleCode: 'project_manager',
  permissions: {'projects.read', kFinancePlanReadPermission},
);

/// Saha: finans izni yok -- hiçbir tutar görmemeli, API çağrılmamalı.
final fpNoAccessUser = buildUser(
  id: 'field',
  roleCode: 'field',
  permissions: {'projects.read', 'projects.tasks.read'},
);

Project financeProject({String status = 'active', String customerName = 'Moda Mimarlık Ltd.'}) => Project.fromJson({
      'id': kProjectId,
      'project_no': 'PRJ-2026-0007',
      'name': 'Kadıköy Ofis Tadilatı',
      'project_type': 'Tadilat',
      'customer_name': customerName,
      'contract_amount': 1250000,
      'currency': 'TRY',
      'status': status,
      'start_date': '2026-06-01',
      'end_date': '2026-12-31',
      'description': '',
      'created_at': '2026-06-01T08:00:00Z',
    });

/// Güncel proje bedeli 1.400.000 (150.000 onaylı ek iş) -- plan toplamı
/// 1.250.000 olduğundan "planlanmamış bakiye" notu çıkar.
FinancialSummary financeSummary({double currentContractValue = 1400000}) => FinancialSummary(
      currentContractValue: currentContractValue,
      collectedAmount: 400000,
      remainingReceivable: currentContractValue - 400000,
      totalExpenses: 310000,
      subcontractorPaid: 120000,
      subcontractorRemaining: 80000,
      realizedCost: 430000,
      committedCost: 900000,
      realizedGrossProfit: -30000,
      estimatedGrossProfit: 500000,
      realizedMarginPercent: -7.5,
      estimatedMarginPercent: 35.7,
      currency: 'TRY',
    );

/// Plan kalemlerine bağlı tahsilatlar -- kalemlerin "Tahsil Edilen"iyle
/// TUTARLI (i1: 250.000 = 250.000; i2: 150.000 = 100.000 + 50.000; iptal
/// edilen c4 sayılmaz).
List<Collection> planCollections() => [
      for (final j in [
        {'id': 'c1', 'payment_plan_item_id': 'i1', 'amount': 250000, 'received_date': '2026-07-30', 'payment_method': 'Havale'},
        {'id': 'c2', 'payment_plan_item_id': 'i2', 'amount': 100000, 'received_date': '2026-09-10', 'payment_method': 'EFT'},
        {'id': 'c3', 'payment_plan_item_id': 'i2', 'amount': 50000, 'received_date': '2026-09-24', 'payment_method': 'Çek'},
        {
          'id': 'c4',
          'payment_plan_item_id': 'i2',
          'amount': 50000,
          'received_date': '2026-09-20',
          'payment_method': 'EFT',
          'voided_at': '2026-09-21T09:00:00Z',
          'void_reason': 'Mükerrer giriş',
        },
      ])
        Collection.fromJson({...j, 'currency': 'TRY'}),
    ];

/// Sunucu sırası (sort_order). Durumlar sunucunun 2026-09-29 itibarıyla
/// türeteceği değerlerdir.
const kPlanItemFixtures = <PaymentPlanItem>[
  PaymentPlanItem(
    id: 'i1',
    sortOrder: 0,
    name: 'Peşinat',
    percentage: 20,
    plannedAmount: 250000,
    collectedAmount: 250000,
    remainingAmount: 0,
    dueDate: '2026-08-01',
    status: kPlanItemPaid,
    notes: 'Sözleşme imzasında tahsil edildi.',
  ),
  PaymentPlanItem(
    id: 'i2',
    sortOrder: 1,
    name: '1. Hakediş',
    percentage: 30,
    plannedAmount: 375000,
    collectedAmount: 150000,
    remainingAmount: 225000,
    dueDate: '2026-09-15',
    status: kPlanItemOverdue,
    notes: 'Kaba inşaat tamamlanınca. Kalan kısım için müşteriye hatırlatma yapıldı.',
  ),
  PaymentPlanItem(
    id: 'i3',
    sortOrder: 2,
    name: '2. Hakediş',
    percentage: null,
    plannedAmount: 375000,
    collectedAmount: 0,
    remainingAmount: 375000,
    dueDate: '2026-10-10',
    status: kPlanItemPending,
  ),
  PaymentPlanItem(
    id: 'i4',
    sortOrder: 3,
    name: 'Kesin Kabul',
    percentage: null,
    plannedAmount: 250000,
    collectedAmount: 0,
    remainingAmount: 250000,
    dueDate: '2026-12-20',
    status: kPlanItemPending,
  ),
  PaymentPlanItem(
    id: 'i5',
    sortOrder: 4,
    name: 'Malzeme Avansı',
    percentage: null,
    plannedAmount: 50000,
    collectedAmount: 0,
    remainingAmount: 50000,
    dueDate: null,
    status: kPlanItemCancelled,
  ),
];

/// Sunucu sırası: fatura tarihi (yeni -> eski).
const kInvoiceFixtures = <ProjectInvoice>[
  ProjectInvoice(
    id: 'f1',
    invoiceNo: 'ARV2026000145',
    invoiceType: kInvoiceTypeSales,
    invoiceDate: '2026-09-20',
    dueDate: '2026-10-20',
    amount: 250000,
    currency: 'TRY',
    status: kInvoiceSent,
    customerName: 'Moda Mimarlık Ltd.',
    createdAt: '2026-09-20T09:15:00Z',
  ),
  ProjectInvoice(
    id: 'f2',
    invoiceNo: 'ALS-88412',
    invoiceType: kInvoiceTypePurchase,
    invoiceDate: '2026-09-05',
    dueDate: '2026-09-10',
    amount: 86400,
    currency: 'TRY',
    status: kInvoiceIssued,
    customerName: 'Kaya Yapı Malzemeleri',
    notes: 'Alçıpan ve profil malzemesi.',
    createdAt: '2026-09-05T11:00:00Z',
  ),
  ProjectInvoice(
    id: 'f3',
    invoiceNo: 'ARV2026000131',
    invoiceType: kInvoiceTypeSales,
    invoiceDate: '2026-08-20',
    dueDate: '2026-09-19',
    amount: 375000,
    currency: 'TRY',
    status: kInvoiceIssued,
    customerName: 'Moda Mimarlık Ltd.',
    notes: '1. hakediş faturası.',
    createdAt: '2026-08-20T10:30:00Z',
  ),
  ProjectInvoice(
    id: 'f4',
    invoiceNo: 'ARV2026000102',
    invoiceType: kInvoiceTypeSales,
    invoiceDate: '2026-07-28',
    dueDate: '2026-08-01',
    amount: 250000,
    currency: 'TRY',
    status: kInvoicePaid,
    customerName: 'Moda Mimarlık Ltd.',
    createdAt: '2026-07-28T08:00:00Z',
  ),
  ProjectInvoice(
    id: 'f5',
    invoiceNo: 'ARV2026000099',
    invoiceType: kInvoiceTypeSales,
    invoiceDate: '2026-07-01',
    dueDate: null,
    amount: 12000,
    currency: 'TRY',
    status: kInvoiceCancelled,
    customerName: 'Moda Mimarlık Ltd.',
    createdAt: '2026-07-01T08:00:00Z',
  ),
];

/// Bellek içi sahte depo: çağrıları ve gövdeleri kaydeder, istenirse hata
/// fırlatır.
class FakeFinancePlanRepository implements FinancePlanRepository {
  FakeFinancePlanRepository({
    List<PaymentPlanItem> items = kPlanItemFixtures,
    List<ProjectInvoice> invoices = kInvoiceFixtures,
  })  : planItems = [...items],
        invoiceItems = [...invoices];

  final List<PaymentPlanItem> planItems;
  final List<ProjectInvoice> invoiceItems;
  final List<String> calls = [];
  final List<PaymentPlanItemInput> createdItems = [];
  final List<(String, PaymentPlanItemInput)> updatedItems = [];
  final List<InvoiceInput> createdInvoices = [];
  final List<(String, String)> statusChanges = [];
  Object? planError;
  Object? invoicesError;
  Object? writeError;

  /// Verilirse yazma çağrıları bu tamamlanana kadar bekler.
  Completer<void>? writeGate;

  double get _plannedTotal =>
      planItems.where((i) => !i.isCancelled).fold<double>(0, (sum, i) => sum + i.plannedAmount);

  Future<void> _write(String call) async {
    calls.add(call);
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
  }

  @override
  Future<PaymentPlan> paymentPlan(String projectId) async {
    calls.add('plan:$projectId');
    if (planError != null) throw planError!;
    return PaymentPlan(items: [...planItems], plannedTotal: _plannedTotal);
  }

  @override
  Future<PaymentPlanItem> createPlanItem(String projectId, PaymentPlanItemInput input) async {
    await _write('createItem:$projectId');
    createdItems.add(input);
    final planned = input.percentage != null ? 1250000 * input.percentage! / 100 : input.plannedAmount!;
    final item = PaymentPlanItem(
      id: 'new${planItems.length + 1}',
      sortOrder: input.sortOrder,
      name: input.name.trim(),
      percentage: input.percentage,
      plannedAmount: planned,
      collectedAmount: 0,
      remainingAmount: planned,
      dueDate: input.dueDate,
      status: kPlanItemPending,
      notes: input.notes.trim(),
    );
    planItems.add(item);
    return item;
  }

  @override
  Future<PaymentPlanItem> updatePlanItem(String projectId, String itemId, PaymentPlanItemInput input) async {
    await _write('updateItem:$itemId');
    updatedItems.add((itemId, input));
    final i = planItems.indexWhere((p) => p.id == itemId);
    final old = planItems[i];
    final planned = input.percentage != null ? 1250000 * input.percentage! / 100 : input.plannedAmount!;
    final item = PaymentPlanItem(
      id: old.id,
      sortOrder: input.sortOrder,
      name: input.name.trim(),
      percentage: input.percentage,
      plannedAmount: planned,
      collectedAmount: old.collectedAmount,
      remainingAmount: (planned - old.collectedAmount).clamp(0, double.infinity).toDouble(),
      dueDate: input.dueDate,
      status: old.status,
      notes: input.notes.trim(),
    );
    planItems[i] = item;
    return item;
  }

  @override
  Future<void> cancelPlanItem(String projectId, String itemId) async {
    await _write('cancelItem:$itemId');
    final i = planItems.indexWhere((p) => p.id == itemId);
    final o = planItems[i];
    planItems[i] = PaymentPlanItem(
      id: o.id,
      sortOrder: o.sortOrder,
      name: o.name,
      percentage: o.percentage,
      plannedAmount: o.plannedAmount,
      collectedAmount: o.collectedAmount,
      remainingAmount: o.remainingAmount,
      dueDate: o.dueDate,
      status: kPlanItemCancelled,
      notes: o.notes,
    );
  }

  @override
  Future<List<ProjectInvoice>> invoices(String projectId) async {
    calls.add('invoices:$projectId');
    if (invoicesError != null) throw invoicesError!;
    return [...invoiceItems];
  }

  @override
  Future<ProjectInvoice> createInvoice(String projectId, InvoiceInput input) async {
    await _write('createInvoice:$projectId');
    createdInvoices.add(input);
    final invoice = ProjectInvoice(
      id: 'nf${invoiceItems.length + 1}',
      invoiceNo: input.invoiceNo.trim(),
      invoiceType: input.invoiceType,
      invoiceDate: input.invoiceDate,
      dueDate: input.dueDate,
      amount: input.amount,
      currency: input.currency,
      status: kInvoiceDraft,
      customerName: input.customerName.trim().isEmpty ? 'Moda Mimarlık Ltd.' : input.customerName.trim(),
      notes: input.notes.trim(),
    );
    invoiceItems.insert(0, invoice);
    return invoice;
  }

  @override
  Future<ProjectInvoice> updateInvoiceStatus(String projectId, String invoiceId, String status) async {
    await _write('invoiceStatus:$invoiceId:$status');
    statusChanges.add((invoiceId, status));
    final i = invoiceItems.indexWhere((f) => f.id == invoiceId);
    final o = invoiceItems[i];
    final updated = ProjectInvoice(
      id: o.id,
      invoiceNo: o.invoiceNo,
      invoiceType: o.invoiceType,
      invoiceDate: o.invoiceDate,
      dueDate: o.dueDate,
      amount: o.amount,
      currency: o.currency,
      status: status,
      customerName: o.customerName,
      notes: o.notes,
      createdAt: o.createdAt,
    );
    invoiceItems[i] = updated;
    return updated;
  }
}

const conflictLocked = ApiException(
  statusCode: 409,
  message: 'tamamlanmış veya iptal edilmiş projede yeni finans hareketi oluşturulamaz',
  kind: ApiErrorKind.conflict,
);

/// Gerçek uygulamadaki yerleşim: `/projeler/:id` altında
/// `financePlanRoutes`. `:id` sayfası yalnızca bir yer tutucudur (proje
/// detayının kendisi project_detail_groups_golden_test'te).
/// [projectCounter] verilirse proje sağlayıcısının kaç kez okunduğunu sayar
/// (409 sonrası tazelemeyi doğrulamak için).
Widget buildFinancePlanApp({
  required User user,
  required FakeFinancePlanRepository repo,
  String location = '/projeler/$kProjectId/odeme-plani',
  Project Function()? project,
  FinancialSummary? summary,
  ThemeData? theme,
  List<int>? projectCounter,
}) {
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/projeler',
        builder: (_, _) => const Scaffold(body: Center(child: Text('Projeler'))),
        routes: [
          GoRoute(
            path: ':id',
            builder: (_, _) => const Scaffold(body: Center(child: Text('Proje'))),
            routes: financePlanRoutes,
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(() => FakeAuth(user)),
      financePlanRepositoryProvider.overrideWithValue(repo),
      projectDetailProvider.overrideWith((ref, id) async {
        projectCounter?.add(1);
        return (project ?? financeProject)();
      }),
      projectFinancialSummaryProvider.overrideWith((ref, id) async => summary ?? financeSummary()),
      projectCollectionsProvider.overrideWith((ref, id) async => planCollections()),
      financePlanTodayProvider.overrideWithValue(kFinanceToday),
    ],
    child: MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: theme ?? AppTheme.light(),
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      routerConfig: router,
    ),
  );
}
