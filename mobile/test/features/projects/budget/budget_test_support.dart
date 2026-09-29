import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/budget/budget_routes.dart';
import 'package:arvend/features/projects/budget/data/budget_providers.dart';
import 'package:arvend/features/projects/budget/data/budget_repository.dart';
import 'package:arvend/features/projects/budget/domain/budget.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/presentation/project_sub_view_bar.dart';

import '../../suppliers/suppliers_test_support.dart' show FakeAuth, buildUser;

export '../../suppliers/suppliers_test_support.dart' show goldenTheme, loadAppFonts, forbidden;

/// Bütçe & Maliyet Kontrolü testlerinin ortak kurulumu: sahte depo (ağ YOK),
/// persona kullanıcıları (router.go izin kodlarıyla), gerçekçi ve TUTARLI
/// fikstürler (backend formülleriyle: revize = orijinal + onaylı revizyon,
/// EAC = gerçekleşen + ETC, varyans = revize − EAC) ve proje detayını taklit
/// eden bir kabuk (Finans > Maliyet Kontrolü segmenti altında sekme).

const kProjectId = 'p1';

const _allBudget = {
  kBudgetReadPermission,
  kBudgetManagePermission,
  kCostControlReadPermission,
  kCostControlManagePermission,
};

/// Sahip: kaba rol admin + tüm bütçe/maliyet + finans + maliyet kodu okuma.
final budgetOwnerUser = buildUser(
  id: 'owner',
  role: UserRole.admin,
  roleCode: 'owner',
  permissions: {..._allBudget, kFinanceReadPermission, kCostCodesReadPermission, 'projects.read'},
);

/// Finans: kaba rol kullanici, yönetim izinleri var (migration 0035 finance).
final budgetFinanceUser = buildUser(
  id: 'finance',
  roleCode: 'finance',
  permissions: {..._allBudget, kFinanceReadPermission, kCostCodesReadPermission, 'projects.read'},
);

/// Proje Yöneticisi: budget.read + cost_control.read + cost_codes.read,
/// finans okuma YOK (migration 0035 rol matrisi) -- salt okunur.
final budgetReadOnlyUser = buildUser(
  id: 'pm',
  roleCode: 'project_manager',
  permissions: {kBudgetReadPermission, kCostControlReadPermission, kCostCodesReadPermission, 'projects.read'},
);

/// Özel rol: yalnızca bütçe (maliyet kontrolü izni yok).
final budgetOnlyUser = buildUser(
  id: 'budget-only',
  roleCode: 'custom',
  permissions: {kBudgetReadPermission, kBudgetManagePermission, 'projects.read'},
);

/// Saha: hiçbir finans/bütçe izni yok.
final budgetFieldUser = buildUser(
  id: 'field',
  roleCode: 'field',
  permissions: {'projects.read', 'projects.tasks.read', 'projects.operations.read'},
);

Project sampleProject({String status = 'active'}) => Project(
  id: kProjectId,
  projectNo: 'PRJ-2026-0012',
  name: 'Ataşehir Konut — B Blok',
  projectType: 'Konut',
  customerName: 'Ataşehir Yapı Kooperatifi',
  customerPhone: '',
  customerEmail: '',
  contractAmount: 18500000,
  currency: 'TRY',
  status: status,
  startDate: '2026-03-01',
  endDate: '2027-06-30',
  description: '',
  createdAt: '2026-02-20T09:00:00Z',
);

// ---------- Fikstürler ----------

const kCostCodes = <OrgCostCode>[
  OrgCostCode(id: 'cc-ekp1', code: 'EKP-001', name: 'Kule Vinç Kirası', isActive: true),
  OrgCostCode(id: 'cc-gnl1', code: 'GNL-001', name: 'Şantiye Genel Giderleri', isActive: true),
  OrgCostCode(id: 'cc-isc1', code: 'ISC-001', name: 'Kalıp İşçiliği', isActive: true),
  OrgCostCode(id: 'cc-mlz1', code: 'MLZ-001', name: 'Hazır Beton', isActive: true),
  OrgCostCode(id: 'cc-mlz2', code: 'MLZ-002', name: 'İnşaat Demiri', isActive: true),
  OrgCostCode(id: 'cc-mlz3', code: 'MLZ-003', name: 'Tuğla', isActive: false),
  OrgCostCode(id: 'cc-mlz4', code: 'MLZ-004', name: 'Alçı Sıva', isActive: true),
  OrgCostCode(id: 'cc-tas1', code: 'TAS-001', name: 'Elektrik Taşeronu', isActive: true),
];

const kWbsNodes = <WbsNode>[
  WbsNode(id: 'w1', code: '01', name: 'Kaba İnşaat', sortOrder: 1),
  WbsNode(id: 'w2', parentId: 'w1', code: '01.01', name: 'Temel', sortOrder: 1),
  WbsNode(id: 'w3', parentId: 'w1', code: '01.02', name: 'Betonarme Karkas', sortOrder: 2),
  WbsNode(id: 'w4', code: '02', name: 'İnce İşler', sortOrder: 2),
  WbsNode(id: 'w5', parentId: 'w4', code: '02.01', name: 'Elektrik Tesisatı', sortOrder: 1),
  WbsNode(id: 'w6', parentId: 'w4', code: '02.02', name: 'Sıva ve Boya', sortOrder: 2, isActive: false),
  WbsNode(id: 'w7', code: '03', name: 'Şantiye Giderleri', sortOrder: 3),
];

const kBudgetLines = <BudgetLine>[
  BudgetLine(
    id: 'l1',
    wbsNodeId: 'w2',
    wbsCode: '01.01',
    wbsName: 'Temel',
    costCodeId: 'cc-mlz1',
    costCodeCode: 'MLZ-001',
    costCodeName: 'Hazır Beton',
    description: 'Temel betonu C30/37',
    quantity: 420,
    unit: 'm³',
    unitCost: 2350,
    originalAmount: 987000,
  ),
  BudgetLine(
    id: 'l2',
    wbsNodeId: 'w3',
    wbsCode: '01.02',
    wbsName: 'Betonarme Karkas',
    costCodeId: 'cc-mlz2',
    costCodeCode: 'MLZ-002',
    costCodeName: 'İnşaat Demiri',
    description: 'Karkas donatısı',
    quantity: 185,
    unit: 'ton',
    unitCost: 24500,
    originalAmount: 4532500,
  ),
  BudgetLine(
    id: 'l3',
    wbsNodeId: 'w3',
    wbsCode: '01.02',
    wbsName: 'Betonarme Karkas',
    costCodeId: 'cc-isc1',
    costCodeCode: 'ISC-001',
    costCodeName: 'Kalıp İşçiliği',
    description: 'Karkas kalıp işçiliği',
    originalAmount: 1850000,
    notes: 'Götürü bedel, 12 kat',
  ),
  BudgetLine(
    id: 'l4',
    wbsNodeId: 'w5',
    wbsCode: '02.01',
    wbsName: 'Elektrik Tesisatı',
    costCodeId: 'cc-tas1',
    costCodeCode: 'TAS-001',
    costCodeName: 'Elektrik Taşeronu',
    description: 'Elektrik tesisatı taşeron işi',
    originalAmount: 2400000,
  ),
  BudgetLine(
    id: 'l5',
    wbsNodeId: 'w7',
    wbsCode: '03',
    wbsName: 'Şantiye Giderleri',
    costCodeId: 'cc-ekp1',
    costCodeCode: 'EKP-001',
    costCodeName: 'Kule Vinç Kirası',
    description: 'Kule vinç kirası (8 ay)',
    quantity: 8,
    unit: 'ay',
    unitCost: 145000,
    originalAmount: 1160000,
  ),
  BudgetLine(
    id: 'l6',
    wbsNodeId: 'w7',
    wbsCode: '03',
    wbsName: 'Şantiye Giderleri',
    costCodeId: 'cc-gnl1',
    costCodeCode: 'GNL-001',
    costCodeName: 'Şantiye Genel Giderleri',
    description: 'Şantiye genel giderleri',
    originalAmount: 780000,
  ),
];

const kBaselinedBudget = ProjectBudget(
  id: 'b1',
  currency: 'TRY',
  status: 'baselined',
  baselinedAt: '2026-09-01T09:30:00Z',
);

const kDraftBudget = ProjectBudget(id: 'b1', currency: 'TRY', status: 'draft');

const kAdjustments = <BudgetAdjustment>[
  BudgetAdjustment(
    id: 'a4',
    budgetLineId: 'l3',
    amount: 120000,
    reason: 'Ek kalıp takımı (çatı katı)',
    status: 'draft',
    createdAt: '2026-09-27T08:15:00Z',
  ),
  BudgetAdjustment(
    id: 'a2',
    budgetLineId: 'l5',
    amount: 145000,
    reason: 'Vinç kirası 1 ay uzatıldı',
    status: 'draft',
    createdAt: '2026-09-25T13:40:00Z',
  ),
  BudgetAdjustment(
    id: 'a1',
    budgetLineId: 'l2',
    amount: 350000,
    reason: 'Demir fiyat artışı (Eylül zammı)',
    status: 'approved',
    createdAt: '2026-09-10T10:00:00Z',
    approvedAt: '2026-09-11T09:00:00Z',
  ),
  BudgetAdjustment(
    id: 'a3',
    budgetLineId: 'l6',
    amount: -60000,
    reason: 'Güvenlik hizmeti kapsam daraltma',
    status: 'rejected',
    createdAt: '2026-09-05T11:20:00Z',
    approvedAt: '2026-09-06T08:30:00Z',
  ),
];

CostControlLine _ccLine({
  String? lineId,
  String wbs = '',
  String wbsName = '',
  required String ccId,
  required String ccCode,
  required String ccName,
  String description = '',
  required double original,
  double adj = 0,
  required double committed,
  required double actual,
  required double etc,
  bool unbudgeted = false,
}) {
  final revised = original + adj;
  final eac = actual + etc;
  return CostControlLine(
    budgetLineId: lineId,
    wbsCode: wbs,
    wbsName: wbsName,
    costCodeId: ccId,
    costCodeCode: ccCode,
    costCodeName: ccName,
    description: description,
    originalBudget: original,
    approvedAdjustments: adj,
    revisedBudget: revised,
    committedCost: committed,
    actualCost: actual,
    etc: etc,
    eac: eac,
    variance: revised - eac,
    isUnbudgeted: unbudgeted,
  );
}

/// Backend sırası: bütçeli satırlar WBS, sonra maliyet kodu; en sonda bütçe dışı.
final kCostControlLines = <CostControlLine>[
  _ccLine(
    lineId: 'l1',
    wbs: '01.01',
    wbsName: 'Temel',
    ccId: 'cc-mlz1',
    ccCode: 'MLZ-001',
    ccName: 'Hazır Beton',
    description: 'Temel betonu C30/37',
    original: 987000,
    committed: 960000,
    actual: 905000,
    etc: 40000,
  ),
  _ccLine(
    lineId: 'l3',
    wbs: '01.02',
    wbsName: 'Betonarme Karkas',
    ccId: 'cc-isc1',
    ccCode: 'ISC-001',
    ccName: 'Kalıp İşçiliği',
    description: 'Karkas kalıp işçiliği',
    original: 1850000,
    committed: 1850000,
    actual: 1120000,
    etc: 730000,
  ),
  _ccLine(
    lineId: 'l2',
    wbs: '01.02',
    wbsName: 'Betonarme Karkas',
    ccId: 'cc-mlz2',
    ccCode: 'MLZ-002',
    ccName: 'İnşaat Demiri',
    description: 'Karkas donatısı',
    original: 4532500,
    adj: 350000,
    committed: 4950000,
    actual: 4610000,
    etc: 420000,
  ),
  _ccLine(
    lineId: 'l4',
    wbs: '02.01',
    wbsName: 'Elektrik Tesisatı',
    ccId: 'cc-tas1',
    ccCode: 'TAS-001',
    ccName: 'Elektrik Taşeronu',
    description: 'Elektrik tesisatı taşeron işi',
    original: 2400000,
    committed: 2400000,
    actual: 640000,
    etc: 1760000,
  ),
  _ccLine(
    lineId: 'l5',
    wbs: '03',
    wbsName: 'Şantiye Giderleri',
    ccId: 'cc-ekp1',
    ccCode: 'EKP-001',
    ccName: 'Kule Vinç Kirası',
    description: 'Kule vinç kirası (8 ay)',
    original: 1160000,
    committed: 1160000,
    actual: 1015000,
    etc: 290000,
  ),
  _ccLine(
    lineId: 'l6',
    wbs: '03',
    wbsName: 'Şantiye Giderleri',
    ccId: 'cc-gnl1',
    ccCode: 'GNL-001',
    ccName: 'Şantiye Genel Giderleri',
    description: 'Şantiye genel giderleri',
    original: 780000,
    committed: 120000,
    actual: 455000,
    etc: 325000,
  ),
  _ccLine(
    ccId: 'cc-mlz4',
    ccCode: 'MLZ-004',
    ccName: 'Alçı Sıva',
    original: 0,
    committed: 85000,
    actual: 38500,
    etc: 0,
    unbudgeted: true,
  ),
];

CostControlSummary summaryFor(List<CostControlLine> lines, {double contract = 18500000, bool? hasBudget}) {
  double sum(double Function(CostControlLine l) f) => lines.fold(0, (a, l) => a + f(l));
  final eac = sum((l) => l.eac);
  final profit = contract - eac;
  return CostControlSummary(
    currency: 'TRY',
    contractValue: contract,
    originalBudget: sum((l) => l.originalBudget),
    approvedAdjustments: sum((l) => l.approvedAdjustments),
    revisedBudget: sum((l) => l.revisedBudget),
    committedCost: sum((l) => l.committedCost),
    actualCost: sum((l) => l.actualCost),
    etc: sum((l) => l.etc),
    eac: eac,
    variance: sum((l) => l.variance),
    forecastProfit: profit,
    forecastMarginPercent: contract == 0 ? 0 : (profit / contract * 100 * 100).round() / 100,
    hasBudget: hasBudget ?? lines.any((l) => !l.isUnbudgeted),
  );
}

CostControlData costControlFixture() => (summary: summaryFor(kCostControlLines), lines: kCostControlLines);

CostControlData emptyCostControl() => (summary: summaryFor(const [], hasBudget: false), lines: const []);

const kCommitments = <Commitment>[
  Commitment(
    id: 'c1',
    budgetLineId: 'l6',
    costCodeId: 'cc-gnl1',
    costCodeCode: 'GNL-001',
    costCodeName: 'Şantiye Genel Giderleri',
    sourceType: 'manual',
    description: 'Şantiye güvenlik hizmeti (Ekim)',
    committedAmount: 120000,
    currency: 'TRY',
    status: 'active',
    committedAt: '2026-09-26',
    voidedAt: null,
    voidReason: '',
  ),
  Commitment(
    id: 'c2',
    budgetLineId: null,
    costCodeId: 'cc-mlz4',
    costCodeCode: 'MLZ-004',
    costCodeName: 'Alçı Sıva',
    sourceType: 'manual',
    description: 'Alçı sıva malzemesi ön sipariş',
    committedAmount: 85000,
    currency: 'TRY',
    status: 'active',
    committedAt: '2026-09-22',
    voidedAt: null,
    voidReason: '',
  ),
  Commitment(
    id: 'c3',
    budgetLineId: 'l2',
    costCodeId: 'cc-mlz2',
    costCodeCode: 'MLZ-002',
    costCodeName: 'İnşaat Demiri',
    sourceType: 'purchase_order',
    description: 'PO-2026-0014 · İnşaat demiri Ø12–Ø20',
    committedAmount: 4950000,
    currency: 'TRY',
    status: 'active',
    committedAt: '2026-09-15',
    voidedAt: null,
    voidReason: '',
  ),
  Commitment(
    id: 'c4',
    budgetLineId: 'l4',
    costCodeId: 'cc-tas1',
    costCodeCode: 'TAS-001',
    costCodeName: 'Elektrik Taşeronu',
    sourceType: 'subcontract',
    description: 'TSN-2026-0003 · Elektrik tesisatı',
    committedAmount: 2400000,
    currency: 'TRY',
    status: 'active',
    committedAt: '2026-09-08',
    voidedAt: null,
    voidReason: '',
  ),
  Commitment(
    id: 'c5',
    budgetLineId: 'l1',
    costCodeId: 'cc-mlz1',
    costCodeCode: 'MLZ-001',
    costCodeName: 'Hazır Beton',
    sourceType: 'manual',
    description: 'Hazır beton — temel dökümü',
    committedAmount: 960000,
    currency: 'TRY',
    status: 'active',
    committedAt: '2026-09-03',
    voidedAt: null,
    voidReason: '',
  ),
  Commitment(
    id: 'c6',
    budgetLineId: 'l5',
    costCodeId: 'cc-ekp1',
    costCodeCode: 'EKP-001',
    costCodeName: 'Kule Vinç Kirası',
    sourceType: 'manual',
    description: 'Kule vinç kira sözleşmesi',
    committedAmount: 1160000,
    currency: 'TRY',
    status: 'active',
    committedAt: '2026-08-28',
    voidedAt: null,
    voidReason: '',
  ),
  Commitment(
    id: 'c7',
    budgetLineId: 'l3',
    costCodeId: 'cc-isc1',
    costCodeCode: 'ISC-001',
    costCodeName: 'Kalıp İşçiliği',
    sourceType: 'manual',
    description: 'Kalıp ekibi avans taahhüdü',
    committedAmount: 45000,
    currency: 'TRY',
    status: 'voided',
    committedAt: '2026-08-20',
    voidedAt: '2026-08-25T10:00:00Z',
    voidReason: 'Taşeron sözleşmesine dahil edildi',
  ),
  Commitment(
    id: 'c8',
    budgetLineId: 'l3',
    costCodeId: 'cc-isc1',
    costCodeCode: 'ISC-001',
    costCodeName: 'Kalıp İşçiliği',
    sourceType: 'manual',
    description: 'Kalıp işçiliği sözleşmesi',
    committedAmount: 1850000,
    currency: 'TRY',
    status: 'active',
    committedAt: '2026-08-15',
    voidedAt: null,
    voidReason: '',
  ),
];

const kForecasts = <CostForecast>[
  CostForecast(budgetLineId: 'l1', etcAmount: 40000, note: 'Kalan döküm 17 m³', updatedAt: '2026-09-24T10:00:00Z'),
  CostForecast(
    budgetLineId: 'l2',
    etcAmount: 420000,
    note: 'Çatı katı donatısı + fire',
    updatedAt: '2026-09-24T10:00:00Z',
  ),
  CostForecast(
    budgetLineId: 'l5',
    etcAmount: 290000,
    note: 'Vinç 2 ay daha gerekli',
    updatedAt: '2026-09-25T10:00:00Z',
  ),
];

const kExpenses = <ActualExpense>[
  ActualExpense(
    id: 'e1',
    description: 'Hazır beton C30 — 2. döküm',
    amount: 312000,
    expenseDate: '2026-09-24',
    costCodeId: 'cc-mlz1',
  ),
  ActualExpense(
    id: 'e2',
    description: 'İnşaat demiri Ø16 teslimatı',
    amount: 1240000,
    expenseDate: '2026-09-18',
    costCodeId: 'cc-mlz2',
  ),
  ActualExpense(
    id: 'e3',
    description: 'Kalıp ekibi hakediş #3',
    amount: 420000,
    expenseDate: '2026-09-12',
    costCodeId: 'cc-isc1',
  ),
  ActualExpense(
    id: 'e4',
    description: 'Vinç kirası — Eylül',
    amount: 145000,
    expenseDate: '2026-09-05',
    costCodeId: 'cc-ekp1',
  ),
  ActualExpense(
    id: 'e5',
    description: 'Alçı sıva (acil alım)',
    amount: 38500,
    expenseDate: '2026-09-02',
    costCodeId: 'cc-mlz4',
  ),
  ActualExpense(id: 'e6', description: 'Yemek ve servis', amount: 18400, expenseDate: '2026-09-01'),
  ActualExpense(
    id: 'e7',
    description: 'Hatalı giriş',
    amount: 5000,
    expenseDate: '2026-09-01',
    voidedAt: '2026-09-01T12:00:00Z',
  ),
];

// ---------- Sahte depo ----------

ApiException conflict(String message) => ApiException(statusCode: 409, message: message, kind: ApiErrorKind.conflict);

/// Bellek içi sahte depo: çağrıları (`calls`) ve gövdeleri kaydeder; her
/// yöntem için `errors[ad]` verilirse o hata fırlatılır.
class FakeBudgetRepository implements BudgetRepository {
  FakeBudgetRepository({
    ProjectBudget? budget = kBaselinedBudget,
    List<BudgetLine> lines = kBudgetLines,
    List<WbsNode> wbs = kWbsNodes,
    List<BudgetAdjustment> adjustments = kAdjustments,
    List<Commitment> commitments = kCommitments,
    List<CostForecast> forecasts = kForecasts,
    CostControlData? costControl,
    List<OrgCostCode> costCodes = kCostCodes,
    List<ActualExpense> expenses = kExpenses,
  }) : budgetValue = budget,
       linesValue = [...lines],
       wbsValue = [...wbs],
       adjustmentsValue = [...adjustments],
       commitmentsValue = [...commitments],
       forecastsValue = [...forecasts],
       costControlValue = costControl ?? costControlFixture(),
       costCodesValue = [...costCodes],
       expensesValue = [...expenses];

  ProjectBudget? budgetValue;
  List<BudgetLine> linesValue;
  List<WbsNode> wbsValue;
  List<BudgetAdjustment> adjustmentsValue;
  List<Commitment> commitmentsValue;
  List<CostForecast> forecastsValue;
  CostControlData costControlValue;
  List<OrgCostCode> costCodesValue;
  List<ActualExpense> expensesValue;

  final List<String> calls = [];
  final Map<String, Object> errors = {};

  /// Yazma çağrılarının girdileri (doğrulama için).
  final List<WbsNodeInput> wbsInputs = [];
  final List<BudgetLineInput> lineInputs = [];
  final List<({String lineId, double amount, String reason})> adjustmentInputs = [];
  final List<ManualCommitmentInput> commitmentInputs = [];
  final List<({String lineId, double etc, String note})> forecastInputs = [];
  final List<({String id, String reason})> voids = [];

  /// Verilirse yazma çağrıları bu tamamlanana kadar bekler.
  Completer<void>? writeGate;

  Future<void> _call(String name) async {
    calls.add(name);
    final key = name.split(':').first;
    if (writeGate != null && !_reads.contains(key)) await writeGate!.future;
    final err = errors[key];
    if (err != null) throw err;
  }

  static const _reads = {
    'wbsNodes',
    'budget',
    'budgetLines',
    'adjustments',
    'commitments',
    'forecasts',
    'costControl',
    'costCodes',
    'expenses',
  };

  int count(String name) => calls.where((c) => c.split(':').first == name).length;

  @override
  Future<List<WbsNode>> wbsNodes(String projectId) async {
    await _call('wbsNodes');
    return [...wbsValue];
  }

  @override
  Future<WbsNode> createWbsNode(String projectId, WbsNodeInput input) async {
    await _call('createWbsNode');
    wbsInputs.add(input);
    final n = WbsNode(
      id: 'w${wbsValue.length + 1}',
      parentId: input.parentId,
      code: input.code,
      name: input.name,
      sortOrder: input.sortOrder,
    );
    wbsValue.add(n);
    return n;
  }

  @override
  Future<WbsNode> updateWbsNode(String projectId, String nodeId, WbsNodeInput input) async {
    await _call('updateWbsNode:$nodeId');
    wbsInputs.add(input);
    final i = wbsValue.indexWhere((n) => n.id == nodeId);
    final old = wbsValue[i];
    final n = WbsNode(
      id: old.id,
      parentId: old.parentId,
      code: input.code,
      name: input.name,
      sortOrder: input.sortOrder,
      isActive: old.isActive,
    );
    wbsValue[i] = n;
    return n;
  }

  @override
  Future<void> archiveWbsNode(String projectId, String nodeId) async {
    await _call('archiveWbsNode:$nodeId');
    final i = wbsValue.indexWhere((n) => n.id == nodeId);
    final old = wbsValue[i];
    wbsValue[i] = WbsNode(
      id: old.id,
      parentId: old.parentId,
      code: old.code,
      name: old.name,
      sortOrder: old.sortOrder,
      isActive: false,
    );
  }

  @override
  Future<ProjectBudget?> budget(String projectId) async {
    await _call('budget');
    return budgetValue;
  }

  @override
  Future<ProjectBudget> createBudget(String projectId) async {
    await _call('createBudget');
    budgetValue = kDraftBudget;
    return budgetValue!;
  }

  @override
  Future<ProjectBudget> baselineBudget(String projectId) async {
    await _call('baselineBudget');
    budgetValue = kBaselinedBudget;
    return budgetValue!;
  }

  @override
  Future<List<BudgetLine>> budgetLines(String projectId) async {
    await _call('budgetLines');
    return budgetValue == null ? const [] : [...linesValue];
  }

  @override
  Future<BudgetLine> createBudgetLine(String projectId, BudgetLineInput input) async {
    await _call('createBudgetLine');
    lineInputs.add(input);
    final line = BudgetLine(
      id: 'l${linesValue.length + 1}',
      costCodeId: input.costCodeId,
      description: input.description,
      originalAmount: input.amountComputedByServer ? input.quantity! * input.unitCost! : input.originalAmount,
    );
    linesValue.add(line);
    return line;
  }

  @override
  Future<BudgetLine> updateBudgetLine(String projectId, String lineId, BudgetLineInput input) async {
    await _call('updateBudgetLine:$lineId');
    lineInputs.add(input);
    final i = linesValue.indexWhere((l) => l.id == lineId);
    final old = linesValue[i];
    final line = BudgetLine(
      id: old.id,
      costCodeId: input.costCodeId,
      costCodeCode: old.costCodeCode,
      costCodeName: old.costCodeName,
      description: input.description,
      originalAmount: input.originalAmount,
    );
    linesValue[i] = line;
    return line;
  }

  @override
  Future<void> deleteBudgetLine(String projectId, String lineId) async {
    await _call('deleteBudgetLine:$lineId');
    linesValue.removeWhere((l) => l.id == lineId);
  }

  @override
  Future<List<BudgetAdjustment>> adjustments(String projectId) async {
    await _call('adjustments');
    return [...adjustmentsValue];
  }

  @override
  Future<BudgetAdjustment> createAdjustment(
    String projectId, {
    required String budgetLineId,
    required double amount,
    required String reason,
  }) async {
    await _call('createAdjustment');
    adjustmentInputs.add((lineId: budgetLineId, amount: amount, reason: reason));
    final a = BudgetAdjustment(
      id: 'a${adjustmentsValue.length + 10}',
      budgetLineId: budgetLineId,
      amount: amount,
      reason: reason,
      status: 'draft',
      createdAt: '2026-09-29T08:00:00Z',
    );
    adjustmentsValue.insert(0, a);
    return a;
  }

  BudgetAdjustment _decide(String id, String status) {
    final i = adjustmentsValue.indexWhere((a) => a.id == id);
    final old = adjustmentsValue[i];
    final a = BudgetAdjustment(
      id: old.id,
      budgetLineId: old.budgetLineId,
      amount: old.amount,
      reason: old.reason,
      status: status,
      createdAt: old.createdAt,
      approvedAt: '2026-09-29T09:00:00Z',
    );
    adjustmentsValue[i] = a;
    return a;
  }

  @override
  Future<BudgetAdjustment> approveAdjustment(String projectId, String adjustmentId) async {
    await _call('approveAdjustment:$adjustmentId');
    return _decide(adjustmentId, 'approved');
  }

  @override
  Future<BudgetAdjustment> rejectAdjustment(String projectId, String adjustmentId) async {
    await _call('rejectAdjustment:$adjustmentId');
    return _decide(adjustmentId, 'rejected');
  }

  @override
  Future<List<Commitment>> commitments(String projectId) async {
    await _call('commitments');
    return [...commitmentsValue];
  }

  @override
  Future<Commitment> createCommitment(String projectId, ManualCommitmentInput input) async {
    // Başarısız denemeler de kaydedilir (idempotency anahtarı testi).
    commitmentInputs.add(input);
    await _call('createCommitment');
    final c = Commitment(
      id: 'c${commitmentsValue.length + 10}',
      budgetLineId: input.budgetLineId,
      costCodeId: input.costCodeId,
      costCodeCode: '',
      costCodeName: '',
      sourceType: 'manual',
      description: input.description,
      committedAmount: input.amount,
      currency: 'TRY',
      status: 'active',
      committedAt: input.committedAt,
      voidedAt: null,
      voidReason: '',
    );
    commitmentsValue.insert(0, c);
    return c;
  }

  @override
  Future<Commitment> voidCommitment(String projectId, String commitmentId, {required String reason}) async {
    await _call('voidCommitment:$commitmentId');
    voids.add((id: commitmentId, reason: reason));
    final i = commitmentsValue.indexWhere((c) => c.id == commitmentId);
    final old = commitmentsValue[i];
    final c = Commitment(
      id: old.id,
      budgetLineId: old.budgetLineId,
      costCodeId: old.costCodeId,
      costCodeCode: old.costCodeCode,
      costCodeName: old.costCodeName,
      sourceType: old.sourceType,
      description: old.description,
      committedAmount: old.committedAmount,
      currency: old.currency,
      status: 'voided',
      committedAt: old.committedAt,
      voidedAt: '2026-09-29T09:00:00Z',
      voidReason: reason,
    );
    commitmentsValue[i] = c;
    return c;
  }

  @override
  Future<List<CostForecast>> forecasts(String projectId) async {
    await _call('forecasts');
    return [...forecastsValue];
  }

  @override
  Future<CostForecast> upsertForecast(
    String projectId,
    String budgetLineId, {
    required double etcAmount,
    String note = '',
  }) async {
    await _call('upsertForecast:$budgetLineId');
    forecastInputs.add((lineId: budgetLineId, etc: etcAmount, note: note));
    final f = CostForecast(budgetLineId: budgetLineId, etcAmount: etcAmount, note: note);
    forecastsValue
      ..removeWhere((x) => x.budgetLineId == budgetLineId)
      ..add(f);
    return f;
  }

  @override
  Future<CostControlData> costControl(String projectId) async {
    await _call('costControl');
    return costControlValue;
  }

  @override
  Future<List<OrgCostCode>> costCodes() async {
    await _call('costCodes');
    return [...costCodesValue];
  }

  @override
  Future<List<ActualExpense>> expenses(String projectId) async {
    await _call('expenses');
    return [...expensesValue];
  }
}

// ---------- Uygulama kabuğu ----------

/// Proje detayının Finans grubunu taklit eder: AppBar + gerçek alt görünüm
/// çip şeridi (`ProjectSubViewBar`, sahibin gördüğü Finans çipleri, seçili
/// "Maliyet Kontrolü") + sekme gövdesi (`BudgetCostControlTab`). Alt ekranlar
/// gerçek `budgetRoutes` ile `/projeler/:id` altına bağlıdır.
class FakeProjectDetailHost extends StatelessWidget {
  const FakeProjectDetailHost({super.key, required this.projectId, required this.project});

  final String projectId;
  final Project project;

  static const _finansChips = [
    (alt: 'finans', label: 'Masraf & Tahsilat'),
    (alt: 'sozlesme', label: 'Sözleşme'),
    (alt: 'odeme-plani', label: 'Ödeme Planı'),
    (alt: 'faturalar', label: 'Faturalar'),
    (alt: 'taseron-odemeleri', label: 'Taşeron Ödemeleri'),
    (alt: 'ek-isler', label: 'Ek İşler'),
    (alt: 'maliyet', label: 'Maliyet Kontrolü'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProjectSubViewBar(items: _finansChips, selected: 'maliyet', onSelected: (_) {}),
          Expanded(
            child: BudgetCostControlTab(projectId: projectId, project: project),
          ),
        ],
      ),
    );
  }
}

String hostPath([String projectId = kProjectId]) => '/projeler/$projectId';

Widget buildBudgetApp({
  required User user,
  required FakeBudgetRepository repo,
  Project? project,
  String? initialLocation,
  ThemeData? theme,
}) {
  final p = project ?? sampleProject();
  final router = GoRouter(
    initialLocation: initialLocation ?? hostPath(),
    routes: [
      GoRoute(
        path: '/projeler/:id',
        builder: (context, state) => FakeProjectDetailHost(projectId: state.pathParameters['id']!, project: p),
        routes: budgetRoutes,
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(() => FakeAuth(user)),
      budgetRepositoryProvider.overrideWithValue(repo),
      projectDetailProvider.overrideWith((ref, id) async => p),
      budgetClockProvider.overrideWithValue(() => DateTime(2026, 9, 29, 10)),
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
