import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:arvend/core/api/api_client.dart';
import 'package:arvend/core/api/api_providers.dart';
import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/domain/subcontract.dart' show OrgCostCode;
import 'package:arvend/features/projects/finance_ledger/data/finance_ledger_providers.dart';
import 'package:arvend/features/projects/finance_ledger/data/finance_ledger_repository.dart';
import 'package:arvend/features/projects/finance_ledger/domain/legacy_subcontractor.dart';
import 'package:arvend/features/projects/finance_plan/data/finance_plan_providers.dart';

import '../contract_co/contract_co_test_support.dart' as cc;
import '../finance_plan/finance_plan_test_support.dart' as fp;

/// Finans defteri (masraf/tahsilat iptali, bağ etiketleri, legacy "Taşeron
/// Ödemeleri") testlerinin ortak kurulumu: sahte depo (ağ YOK), personalar
/// ve fikstürler. Tahsilat/masraf iptali ProjectsRepository üzerinden gider
/// -- testler bunu sahte HTTP adaptörüyle doğrular.

User ledgerUser(String id, Set<String> permissions, {UserRole role = UserRole.kullanici}) =>
    cc.buildUser(id: id, role: role, roleCode: id, permissions: permissions);

/// Sahip: finans okuma + yazma + maliyet kodları.
final ledgerOwner = ledgerUser(
  'owner',
  {'projects.read', 'projects.finance.read', 'projects.finance.manage', 'organization.cost_codes.read'},
  role: UserRole.admin,
);

/// Yalnızca finans görüntüleme: satırlar açılır, iptal/ekle yok.
final ledgerViewer = ledgerUser('viewer', {'projects.read', 'projects.finance.read'});

/// Onaylayıcı (Sahip/Yönetici/Finans varsayılanı): finans + masraf onayı.
final ledgerApprover = ledgerUser(
  'approver',
  {
    'projects.read',
    'projects.finance.read',
    'projects.finance.manage',
    'organization.cost_codes.read',
    'projects.expenses.approve',
  },
  role: UserRole.admin,
);

/// Proje Yöneticisi: finans izni YOK -- hiçbir tutar, hiçbir finans isteği.
final ledgerPm = ledgerUser('project_manager', {'projects.read', 'projects.contracts.read', 'projects.tasks.read'});

final ledgerExpenses = [
  Expense.fromJson({
    'id': 'e1',
    'category': 'material',
    'description': 'Alçıpan ve profil',
    'amount': 84500,
    'currency': 'TRY',
    'expense_date': '2026-09-12',
    'supplier_name': 'Yapı Market',
    'invoice_no': 'YM-1042',
    'notes': 'Zemin kat için ikinci sevkiyat',
    'change_order_id': 'co1',
    'cost_code_id': 'cc1',
    'created_at': '2026-09-12T09:00:00Z',
  }),
  Expense.fromJson({
    'id': 'e2',
    'category': 'transport',
    'description': 'Hafriyat nakliyesi',
    'amount': 12000,
    'currency': 'TRY',
    'expense_date': '2026-09-08',
    'supplier_name': '',
    'invoice_no': '',
    'voided_at': '2026-09-09T10:00:00Z',
    'void_reason': 'Mükerrer giriş',
    'created_at': '2026-09-08T09:00:00Z',
  }),
];

/// Masraf onayı fikstürü: onaylı (e1), onay bekleyen (e3), reddedilen (e4).
final approvalExpenses = [
  ledgerExpenses.first,
  Expense.fromJson({
    'id': 'e3',
    'category': 'food',
    'description': 'Ekip yemeği',
    'amount': 3250.5,
    'currency': 'TRY',
    'expense_date': '2026-09-20',
    'supplier_name': 'Lokanta',
    'approval_status': 'pending',
    'created_at': '2026-09-20T12:00:00Z',
  }),
  Expense.fromJson({
    'id': 'e4',
    'category': 'equipment',
    'description': 'Kırıcı kiralama',
    'amount': 18000,
    'currency': 'TRY',
    'expense_date': '2026-09-18',
    'approval_status': 'rejected',
    'decided_at': '2026-09-19T08:30:00Z',
    'decision_note': 'Fatura eksik',
    'created_at': '2026-09-18T09:00:00Z',
  }),
];

final ledgerCollections = [
  Collection.fromJson({
    'id': 'c1',
    'payment_plan_item_id': 'i1',
    'amount': 250000,
    'currency': 'TRY',
    'received_date': '2026-08-01',
    'payment_method': 'Havale',
    'description': 'Peşinat',
    'reference_no': 'EFT-7781',
    'created_at': '2026-08-01T09:00:00Z',
  }),
];

final ledgerChangeOrders = [
  ChangeOrder.fromJson({
    'id': 'co1',
    'change_order_no': 'EK-2026-0003',
    'change_type': 'addition',
    'title': 'Toplantı odası cam bölme',
    'status': 'approved',
    'grand_total': 96000,
    'currency': 'TRY',
    'created_at': '2026-09-05T09:00:00Z',
  }),
];

final ledgerCostCodes = [
  OrgCostCode.fromJson({'id': 'cc1', 'code': '03.20', 'name': 'Kuru duvar', 'is_active': true}),
];

const kLegacySubcontractors = [
  LegacySubcontractor(
    id: 's1',
    name: 'Yılmaz Elektrik',
    companyName: 'Yılmaz Elektrik Taahhüt Ltd.',
    workDescription: 'Zemin kat elektrik tesisatı',
    contractAmount: 180000,
    paidAmount: 120000,
    remainingAmount: 60000,
    currency: 'TRY',
    status: 'active',
  ),
  LegacySubcontractor(
    id: 's2',
    name: 'Demir Boya',
    companyName: '',
    workDescription: 'İç cephe boya',
    contractAmount: 45000,
    paidAmount: 0,
    remainingAmount: 45000,
    currency: 'TRY',
    status: 'planned',
  ),
];

const kLegacyPayments = [
  LegacySubcontractorPayment(
    id: 'sp1',
    subcontractorId: 's1',
    amount: 80000,
    currency: 'TRY',
    paidDate: '2026-09-10',
    description: '1. ödeme',
  ),
  LegacySubcontractorPayment(
    id: 'sp2',
    subcontractorId: 's1',
    amount: 40000,
    currency: 'TRY',
    paidDate: '2026-09-24',
    description: '2. ödeme',
  ),
  LegacySubcontractorPayment(
    id: 'sp3',
    subcontractorId: 's1',
    amount: 5000,
    currency: 'TRY',
    paidDate: '2026-09-25',
    description: 'Yanlış giriş',
    voidedAt: '2026-09-25T12:00:00Z',
    voidReason: 'Mükerrer',
  ),
];

const ledgerForbidden =
    ApiException(statusCode: 403, message: 'bu işlem için yetkiniz yok', kind: ApiErrorKind.forbidden);

class FakeFinanceLedgerRepository implements FinanceLedgerRepository {
  FakeFinanceLedgerRepository({
    List<LegacySubcontractor> subcontractors = kLegacySubcontractors,
    List<LegacySubcontractorPayment> payments = kLegacyPayments,
    this.listError,
  })  : subs = [...subcontractors],
        pays = [...payments];

  final List<LegacySubcontractor> subs;
  final List<LegacySubcontractorPayment> pays;
  final Object? listError;
  final List<String> calls = [];
  final List<Map<String, Object?>> createdSubcontractors = [];
  final List<Map<String, Object?>> createdPayments = [];

  @override
  Future<List<LegacySubcontractor>> subcontractors(String projectId) async {
    calls.add('subcontractors');
    if (listError != null) throw listError!;
    return subs;
  }

  @override
  Future<List<LegacySubcontractorPayment>> subcontractorPayments(String projectId) async {
    calls.add('payments');
    if (listError != null) throw listError!;
    return pays;
  }

  @override
  Future<LegacySubcontractor> createSubcontractor(
    String projectId, {
    required String name,
    required double contractAmount,
    required String currency,
    String companyName = '',
    String workDescription = '',
    double? profitPercent,
  }) async {
    calls.add('createSubcontractor');
    createdSubcontractors.add({
      'name': name,
      'company_name': companyName,
      'work_description': workDescription,
      'contract_amount': contractAmount,
      'currency': currency,
      'profit_percent': profitPercent,
    });
    final created = LegacySubcontractor(
      id: 's${subs.length + 1}',
      name: name,
      companyName: companyName,
      workDescription: workDescription,
      contractAmount: contractAmount,
      paidAmount: 0,
      remainingAmount: contractAmount,
      currency: currency,
      status: 'active',
    );
    subs.add(created);
    return created;
  }

  final List<Map<String, Object?>> updatedSubcontractors = [];
  final List<Map<String, Object?>> voidedPayments = [];

  @override
  Future<LegacySubcontractor> updateSubcontractor(
    String projectId,
    LegacySubcontractor existing, {
    required String name,
    required String companyName,
    required String workDescription,
    required double contractAmount,
    double? profitPercent,
  }) async {
    calls.add('updateSubcontractor');
    updatedSubcontractors.add({
      'id': existing.id,
      'name': name,
      'company_name': companyName,
      'work_description': workDescription,
      'contract_amount': contractAmount,
      'profit_percent': profitPercent,
    });
    final updated = LegacySubcontractor(
      id: existing.id,
      name: name,
      companyName: companyName,
      workDescription: workDescription,
      contractAmount: contractAmount,
      paidAmount: existing.paidAmount,
      remainingAmount: contractAmount - existing.paidAmount,
      currency: existing.currency,
      status: existing.status,
    );
    subs[subs.indexWhere((s) => s.id == existing.id)] = updated;
    return updated;
  }

  @override
  Future<void> voidSubcontractorPayment(String projectId, String paymentId, {String reason = ''}) async {
    calls.add('voidPayment');
    voidedPayments.add({'payment_id': paymentId, 'reason': reason});
  }

  @override
  Future<LegacySubcontractorPayment> createSubcontractorPayment(
    String projectId,
    String subcontractorId, {
    required double amount,
    required String currency,
    required String paidDate,
    required String idempotencyKey,
    String description = '',
  }) async {
    calls.add('createPayment');
    createdPayments.add({
      'subcontractor_id': subcontractorId,
      'amount': amount,
      'currency': currency,
      'paid_date': paidDate,
      'description': description,
      'idempotency_key': idempotencyKey,
    });
    return LegacySubcontractorPayment(
      id: 'sp${pays.length + 1}',
      subcontractorId: subcontractorId,
      amount: amount,
      currency: currency,
      paidDate: paidDate,
      description: description,
    );
  }
}

/// Defter ekranları için ProviderScope: sahte defter deposu + proje
/// listeleri; tahsilat/masraf iptali [client] (sahte HTTP) üzerinden.
Widget buildLedgerApp({
  required User user,
  required ApiClient client,
  required Widget home,
  FakeFinanceLedgerRepository? repo,
  Project? project,
  List<Expense>? expenses,
  List<Collection>? collections,
  ThemeData? theme,
}) {
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(client),
      authControllerProvider.overrideWith(() => cc.FakeAuth(user)),
      financeLedgerRepositoryProvider.overrideWithValue(repo ?? FakeFinanceLedgerRepository()),
      financePlanRepositoryProvider.overrideWithValue(fp.FakeFinancePlanRepository()),
      projectDetailProvider.overrideWith((ref, id) async => project ?? cc.sampleProject()),
      projectExpensesProvider.overrideWith((ref, id) async => expenses ?? ledgerExpenses),
      projectCollectionsProvider.overrideWith((ref, id) async => collections ?? ledgerCollections),
      projectChangeOrdersProvider.overrideWith((ref, id) async => ledgerChangeOrders),
      orgCostCodesProvider.overrideWith((ref) async => ledgerCostCodes),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme ?? AppTheme.light(),
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: home,
    ),
  );
}
