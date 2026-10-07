import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:arvend/core/auth/auth_controller.dart';
import 'package:arvend/core/errors/api_exception.dart';
import 'package:arvend/core/theme/app_theme.dart';
import 'package:arvend/features/auth/domain/user.dart';
import 'package:arvend/features/projects/contract_co/contract_co_routes.dart';
import 'package:arvend/features/projects/contract_co/data/contract_co_providers.dart';
import 'package:arvend/features/projects/contract_co/data/contract_co_repository.dart';
import 'package:arvend/features/projects/contract_co/domain/project_change_order.dart';
import 'package:arvend/features/projects/contract_co/domain/project_contract.dart';
import 'package:arvend/features/projects/data/projects_providers.dart';
import 'package:arvend/features/projects/domain/project.dart';
import 'package:arvend/features/projects/presentation/project_sub_view_bar.dart';

/// Sözleşme + Ek İşler testlerinin ortak kurulumu: sahte depo (ağ YOK),
/// persona kullanıcıları, gerçek rota ağacı (`contractCoRoutes`,
/// `/projeler/:id` altında) ve golden testleri için uygulama fontları.

User buildUser({
  String id = 'u1',
  UserRole role = UserRole.kullanici,
  Set<String> permissions = const {},
  String roleCode = 'custom',
}) =>
    User(
      id: id,
      organizationId: 'org1',
      username: 'test.$id',
      fullName: 'Test Kullanıcı',
      role: role,
      isActive: true,
      mustChangePassword: false,
      onboardingCompleted: true,
      onboardingStep: 'completed',
      organizationName: 'Deneme Yapı',
      organizationRoleCode: roleCode,
      permissions: permissions,
    );

const _allPerms = {
  'projects.read',
  'projects.update',
  'projects.finance.read',
  'projects.finance.manage',
  'projects.contracts.read',
  'projects.contracts.manage',
  'projects.contracts.lifecycle',
};

/// Sahip: kaba rol admin + tam izin (müşteri kararını kaydetme dahil --
/// migration 0063 varsayılanı Sahip/Yönetici).
final ownerUser = buildUser(
  id: 'owner',
  role: UserRole.admin,
  roleCode: 'owner',
  permissions: {..._allPerms, 'projects.change_orders.approve'},
);

/// Finans: kaba rol kullanici, sözleşme + finans tam (rol matrisi §5.1).
final financeUser = buildUser(id: 'finance', roleCode: 'finance', permissions: _allPerms);

/// Proje Yöneticisi: sözleşme taslağını düzenler ama durumunu değiştiremez;
/// finans (tutar) göremez.
final pmUser = buildUser(
  id: 'pm',
  roleCode: 'project_manager',
  permissions: {'projects.read', 'projects.contracts.read', 'projects.contracts.manage'},
);

/// Yalnızca görüntüleme (sözleşme + finans okuma).
final readOnlyUser = buildUser(
  id: 'viewer',
  permissions: {'projects.read', 'projects.contracts.read', 'projects.finance.read'},
);

/// Saha: projeyi görür, sözleşme/finans izni yok.
final fieldUser = buildUser(id: 'field', roleCode: 'field', permissions: {'projects.read', 'projects.tasks.read'});

Project sampleProject({String status = 'active'}) => Project.fromJson({
      'id': 'p1',
      'project_no': 'PRJ-2026-0007',
      'name': 'Kadıköy Ofis Tadilatı',
      'project_type': 'Tadilat',
      'customer_name': 'Moda Mimarlık Ltd.',
      'customer_email': 'satinalma@modamimarlik.com',
      'contract_amount': 1250000,
      'currency': 'TRY',
      'status': status,
      'start_date': '2026-09-01',
      'end_date': '2026-12-15',
      'description': '',
      'created_at': '2026-09-01T08:00:00Z',
    });

ProjectContract sampleContract({String status = ProjectContract.statusDraft}) => ProjectContract(
      id: 'k1',
      currency: 'TRY',
      status: status,
      scope: 'Zemin kat asma tavan, bölme duvar ve elektrik tesisatı yenileme işleri.',
      paymentTerms: 'Aylık hakediş, fatura tarihinden itibaren 30 gün içinde ödeme.',
      retentionTerms: 'Her hakedişten %5 teminat kesintisi.',
      advanceTerms: 'Sözleşme bedelinin %20\'si avans, hakedişlerden mahsup.',
      effectiveDate: '2026-09-01',
      plannedCompletionDate: '2026-12-15',
      internalNotes: status == ProjectContract.statusDraft ? 'Avans oranı müşteriyle tekrar görüşülecek.' : '',
      createdAt: '2026-09-01T07:30:00Z',
      updatedAt: '2026-09-02T09:00:00Z',
      activatedAt: status == ProjectContract.statusActive ? '2026-09-03T10:15:00Z' : null,
    );

const kItemsCo3 = [
  ProjectChangeOrderItem(
    id: 'i31',
    description: 'Ek priz hattı (toplantı odası)',
    quantity: 12,
    unit: 'adet',
    unitPrice: 850,
    lineTotal: 10200,
    productId: 'prod-9',
    estimatedUnitCost: 520,
    estimatedCost: 6240,
  ),
  ProjectChangeOrderItem(
    id: 'i32',
    description: 'Kablo kanalı',
    quantity: 36.5,
    unit: 'm',
    unitPrice: 120,
    lineTotal: 4380,
    sortOrder: 1,
  ),
];

const _profit = ChangeOrderProfitability(
  revenueEffect: 96000,
  realizedCost: 41000,
  committedCost: 52000,
  realizedProfit: 55000,
  estimatedProfit: 44000,
  realizedMarginPercent: 57.3,
  estimatedMarginPercent: 45.8,
);

List<ProjectChangeOrder> sampleChangeOrders() => [
      const ProjectChangeOrder(
        id: 'co1',
        projectId: 'p1',
        sequenceNo: 1,
        changeOrderNo: 'EK-001',
        changeType: ProjectChangeOrder.typeAddition,
        title: 'Mutfak dolabı ilavesi',
        status: ProjectChangeOrder.statusApproved,
        currency: 'TRY',
        subtotal: 80000,
        vatRate: 20,
        vatAmount: 16000,
        grandTotal: 96000,
        createdAt: '2026-09-05T08:00:00Z',
        sentAt: '2026-09-05T09:00:00Z',
        respondedAt: '2026-09-06T14:20:00Z',
        approvedAt: '2026-09-06T14:20:00Z',
        profitability: _profit,
        items: [
          ProjectChangeOrderItem(
            id: 'i11',
            description: 'Mutfak dolabı (üst + alt modül)',
            quantity: 1,
            unit: 'takım',
            unitPrice: 65000,
            lineTotal: 65000,
          ),
          ProjectChangeOrderItem(
            id: 'i12',
            description: 'Kuvars tezgah',
            quantity: 3,
            unit: 'm',
            unitPrice: 5000,
            lineTotal: 15000,
            sortOrder: 1,
          ),
        ],
      ),
      const ProjectChangeOrder(
        id: 'co2',
        projectId: 'p1',
        sequenceNo: 2,
        changeOrderNo: 'EK-002',
        changeType: ProjectChangeOrder.typeAddition,
        title: 'Toplantı odası elektrik ilavesi',
        status: ProjectChangeOrder.statusSuperseded,
        currency: 'TRY',
        subtotal: 12160,
        vatRate: 20,
        vatAmount: 2432,
        grandTotal: 14592,
        createdAt: '2026-09-10T08:00:00Z',
        sentAt: '2026-09-10T09:00:00Z',
      ),
      const ProjectChangeOrder(
        id: 'co3',
        projectId: 'p1',
        sequenceNo: 3,
        changeOrderNo: 'EK-003',
        changeType: ProjectChangeOrder.typeAddition,
        title: 'Toplantı odası elektrik ilavesi',
        description: 'Müşterinin istediği ek priz hattı ve kablo kanalı.',
        status: ProjectChangeOrder.statusDraft,
        currency: 'TRY',
        subtotal: 14580,
        vatRate: 20,
        vatAmount: 2916,
        grandTotal: 17496,
        customerNotes: 'Çalışma hafta sonu yapılacaktır.',
        internalNotes: 'Malzeme depoda mevcut.',
        createdAt: '2026-09-12T08:00:00Z',
        supersedesChangeOrderId: 'co2',
        items: kItemsCo3,
        profitability: ChangeOrderProfitability(
          revenueEffect: 17496,
          realizedCost: 0,
          committedCost: 0,
          realizedProfit: 17496,
          estimatedProfit: 17496,
          realizedMarginPercent: 100,
          estimatedMarginPercent: 100,
        ),
      ),
      const ProjectChangeOrder(
        id: 'co4',
        projectId: 'p1',
        sequenceNo: 4,
        changeOrderNo: 'EK-004',
        changeType: ProjectChangeOrder.typeDeduction,
        title: 'Seramik kaplama iptali (arşiv odası)',
        status: ProjectChangeOrder.statusSent,
        currency: 'TRY',
        subtotal: 25000,
        vatRate: 20,
        vatAmount: 5000,
        grandTotal: 30000,
        createdAt: '2026-09-15T08:00:00Z',
        sentAt: '2026-09-15T11:40:00Z',
        activeShareToken: '6f1c2d3e-aaaa-bbbb-cccc-1234567890ab',
        items: [
          ProjectChangeOrderItem(
            id: 'i41',
            description: 'Seramik kaplama (arşiv odası)',
            quantity: 50,
            unit: 'm²',
            unitPrice: 500,
            lineTotal: 25000,
          ),
        ],
      ),
      const ProjectChangeOrder(
        id: 'co5',
        projectId: 'p1',
        sequenceNo: 5,
        changeOrderNo: 'EK-005',
        changeType: ProjectChangeOrder.typeAddition,
        title: 'Cephe boyası renk değişikliği',
        status: ProjectChangeOrder.statusRejected,
        currency: 'TRY',
        subtotal: 9000,
        vatRate: 20,
        vatAmount: 1800,
        grandTotal: 10800,
        createdAt: '2026-09-16T08:00:00Z',
        sentAt: '2026-09-16T10:00:00Z',
        respondedAt: '2026-09-17T16:05:00Z',
        rejectedAt: '2026-09-17T16:05:00Z',
        // Ara toplam (9.000) kalemlerden gelir -- kalemsiz bir ek iş sunucuda
        // oluşamaz ("en az bir kalem ve toplam > 0").
        items: [
          ProjectChangeOrderItem(
            id: 'i51',
            description: 'Cephe boyası (renk değişikliği farkı)',
            quantity: 450,
            unit: 'm²',
            unitPrice: 20,
            lineTotal: 9000,
          ),
        ],
      ),
    ];

const sampleSummary = ContractValueSummary(
  baseContractAmount: 1250000,
  approvedAdditions: 96000,
  approvedDeductions: 0,
  currentContractValue: 1346000,
  pendingAdditions: 0,
  pendingDeductions: 30000,
  potentialContractValue: 1316000,
  currency: 'TRY',
);

List<ChangeOrderEvent> sampleEvents() => const [
      ChangeOrderEvent(id: 'a1', eventType: 'change_order_created', createdAt: '2026-09-05T08:00:00Z', changeOrderIds: {'co1'}),
      ChangeOrderEvent(id: 'a2', eventType: 'change_order_sent', createdAt: '2026-09-05T09:00:00Z', changeOrderIds: {'co1'}),
      ChangeOrderEvent(id: 'a3', eventType: 'change_order_viewed', createdAt: '2026-09-06T14:10:00Z', changeOrderIds: {'co1'}),
      ChangeOrderEvent(id: 'a4', eventType: 'change_order_approved', createdAt: '2026-09-06T14:20:00Z', changeOrderIds: {'co1'}),
      ChangeOrderEvent(id: 'e1', eventType: 'change_order_created', createdAt: '2026-09-15T08:00:00Z', changeOrderIds: {'co4'}),
      ChangeOrderEvent(id: 'e2', eventType: 'change_order_sent', createdAt: '2026-09-15T11:40:00Z', changeOrderIds: {'co4'}),
      ChangeOrderEvent(
        id: 'e3',
        eventType: 'change_order_email_sent',
        createdAt: '2026-09-15T11:42:00Z',
        changeOrderIds: {'co4'},
        recipient: 'satinalma@modamimarlik.com',
      ),
      ChangeOrderEvent(id: 'e4', eventType: 'change_order_viewed', createdAt: '2026-09-15T13:05:00Z', changeOrderIds: {'co4'}),
      ChangeOrderEvent(id: 'e5', eventType: 'change_order_viewed', createdAt: '2026-09-16T09:30:00Z', changeOrderIds: {'co4'}),
      ChangeOrderEvent(
        id: 'e6',
        eventType: 'change_order_superseded',
        createdAt: '2026-09-12T08:00:00Z',
        changeOrderIds: {'co2', 'co3'},
        newChangeOrderId: 'co3',
      ),
    ];

const forbidden = ApiException(statusCode: 403, message: 'bu işlem için yetkiniz yok', kind: ApiErrorKind.forbidden);

ApiException conflict(String message) =>
    ApiException(statusCode: 409, message: message, kind: ApiErrorKind.conflict);

/// Bellek içi sahte depo: çağrıları kaydeder, durum geçişlerini uygular,
/// istenirse hata fırlatır.
class FakeContractCoRepository implements ContractCoRepository {
  FakeContractCoRepository({
    ProjectContract? contract,
    bool noContract = false,
    List<ProjectChangeOrder>? changeOrders,
    this.summary = sampleSummary,
    List<ChangeOrderEvent>? events,
  })  : currentContract = noContract ? null : (contract ?? sampleContract()),
        store = changeOrders ?? sampleChangeOrders(),
        events = events ?? sampleEvents();

  /// Sunucudaki sözleşme (`null` = yok, 404).
  ProjectContract? currentContract;

  /// Sunucudaki ek işler (tam DTO, kalemlerle).
  List<ProjectChangeOrder> store;
  ContractValueSummary summary;
  List<ChangeOrderEvent> events;

  final List<String> calls = [];
  final List<ContractDraftInput> draftUpdates = [];
  final List<String> notesUpdates = [];
  final List<String> reasons = [];
  final List<ChangeOrderInput> created = [];
  final List<(String, ChangeOrderInput)> updated = [];
  final List<ChangeOrderEmailInput> emails = [];
  final List<({String id, bool approved, String note})> decisions = [];

  Object? contractError;
  Object? listError;
  Object? detailError;
  Object? writeError;
  Completer<void>? writeGate;

  Future<void> _write(String call) async {
    calls.add(call);
    if (writeGate != null) await writeGate!.future;
    if (writeError != null) throw writeError!;
  }

  ProjectContract _withStatus(String status, {String cancelReason = '', String terminationReason = ''}) {
    final c = currentContract!;
    return ProjectContract(
      id: c.id,
      currency: c.currency,
      status: status,
      scope: c.scope,
      paymentTerms: c.paymentTerms,
      retentionTerms: c.retentionTerms,
      advanceTerms: c.advanceTerms,
      effectiveDate: c.effectiveDate,
      plannedCompletionDate: c.plannedCompletionDate,
      internalNotes: c.internalNotes,
      createdAt: c.createdAt,
      activatedAt: status == ProjectContract.statusActive ? '2026-09-20T10:00:00Z' : c.activatedAt,
      cancelledAt: status == ProjectContract.statusCancelled ? '2026-09-20T10:00:00Z' : null,
      cancelReason: cancelReason,
      terminatedAt: status == ProjectContract.statusTerminated ? '2026-09-20T10:00:00Z' : null,
      terminationReason: terminationReason,
    );
  }

  // ---------- Sözleşme ----------

  @override
  Future<ProjectContract?> contract(String projectId) async {
    calls.add('contract');
    if (contractError != null) throw contractError!;
    return currentContract;
  }

  @override
  Future<ProjectContract> createContract(String projectId) async {
    await _write('createContract');
    currentContract = const ProjectContract(id: 'k-new', currency: 'TRY', status: ProjectContract.statusDraft);
    return currentContract!;
  }

  @override
  Future<ProjectContract> updateContractDraft(String projectId, ContractDraftInput input) async {
    await _write('updateContractDraft');
    draftUpdates.add(input);
    final c = currentContract!;
    currentContract = ProjectContract(
      id: c.id,
      currency: c.currency,
      status: c.status,
      scope: input.scope,
      paymentTerms: input.paymentTerms,
      retentionTerms: input.retentionTerms,
      advanceTerms: input.advanceTerms,
      effectiveDate: input.effectiveDate,
      plannedCompletionDate: input.plannedCompletionDate,
      internalNotes: c.internalNotes,
      createdAt: c.createdAt,
    );
    return currentContract!;
  }

  @override
  Future<ProjectContract> updateContractNotes(String projectId, String internalNotes) async {
    await _write('updateContractNotes');
    notesUpdates.add(internalNotes);
    final c = currentContract!;
    currentContract = ProjectContract(
      id: c.id,
      currency: c.currency,
      status: c.status,
      scope: c.scope,
      paymentTerms: c.paymentTerms,
      retentionTerms: c.retentionTerms,
      advanceTerms: c.advanceTerms,
      effectiveDate: c.effectiveDate,
      plannedCompletionDate: c.plannedCompletionDate,
      internalNotes: internalNotes,
      createdAt: c.createdAt,
      activatedAt: c.activatedAt,
    );
    return currentContract!;
  }

  @override
  Future<ProjectContract> activateContract(String projectId) async {
    await _write('activateContract');
    return currentContract = _withStatus(ProjectContract.statusActive);
  }

  @override
  Future<ProjectContract> completeContract(String projectId) async {
    await _write('completeContract');
    return currentContract = _withStatus(ProjectContract.statusCompleted);
  }

  @override
  Future<ProjectContract> cancelContract(String projectId, {required String reason}) async {
    await _write('cancelContract');
    reasons.add(reason);
    return currentContract = _withStatus(ProjectContract.statusCancelled, cancelReason: reason);
  }

  @override
  Future<ProjectContract> terminateContract(String projectId, {required String reason}) async {
    await _write('terminateContract');
    reasons.add(reason);
    return currentContract = _withStatus(ProjectContract.statusTerminated, terminationReason: reason);
  }

  // ---------- Ek İşler ----------

  @override
  Future<List<ProjectChangeOrder>> changeOrders(String projectId) async {
    calls.add('changeOrders');
    if (listError != null) throw listError!;
    // Liste ucu kalem TAŞIMAZ (gerçek backend ile aynı).
    return [
      for (final co in store)
        ProjectChangeOrder.fromJson({..._toJson(co), 'items': null}).withProfitability(co.profitability),
    ];
  }

  @override
  Future<ProjectChangeOrder> changeOrder(String projectId, String changeOrderId) async {
    calls.add('changeOrder:$changeOrderId');
    if (detailError != null) throw detailError!;
    final co = store.firstWhere(
          (c) => c.id == changeOrderId,
          orElse: () => throw const ApiException(statusCode: 404, message: 'proje bulunamadı', kind: ApiErrorKind.notFound),
        );
    // Detay ucu kârlılık HESAPLAMAZ (gerçek backend ile aynı).
    return ProjectChangeOrder.fromJson({..._toJson(co), 'profitability': null});
  }

  void _replace(ProjectChangeOrder co) {
    final i = store.indexWhere((c) => c.id == co.id);
    if (i >= 0) {
      store[i] = co;
    } else {
      store.add(co);
    }
  }

  ProjectChangeOrder _copy(ProjectChangeOrder co, Map<String, dynamic> patch) =>
      ProjectChangeOrder.fromJson({..._toJson(co), ...patch}).withProfitability(co.profitability);

  @override
  Future<ProjectChangeOrder> createChangeOrder(String projectId, ChangeOrderInput input) async {
    await _write('createChangeOrder');
    created.add(input);
    final seq = store.length + 1;
    final co = ProjectChangeOrder(
      id: 'co-new',
      projectId: projectId,
      sequenceNo: seq,
      changeOrderNo: 'EK-${seq.toString().padLeft(3, '0')}',
      changeType: input.changeType,
      title: input.title,
      status: ProjectChangeOrder.statusDraft,
      currency: 'TRY',
      vatRate: input.vatRate,
      items: [
        for (final (i, it) in input.items.indexed)
          ProjectChangeOrderItem(
            id: 'n$i',
            description: it.description,
            quantity: it.quantity,
            unit: it.unit,
            unitPrice: it.unitPrice,
            lineTotal: it.quantity * it.unitPrice,
          ),
      ],
    );
    store.add(co);
    return co;
  }

  @override
  Future<ProjectChangeOrder> updateChangeOrder(String projectId, String changeOrderId, ChangeOrderInput input) async {
    await _write('updateChangeOrder:$changeOrderId');
    updated.add((changeOrderId, input));
    final co = store.firstWhere((c) => c.id == changeOrderId);
    final next = _copy(co, {'title': input.title, 'change_type': input.changeType});
    _replace(next);
    return next;
  }

  @override
  Future<ProjectChangeOrder> sendChangeOrder(String projectId, String changeOrderId) async {
    await _write('sendChangeOrder:$changeOrderId');
    final co = store.firstWhere((c) => c.id == changeOrderId);
    final next = _copy(co, {
      'status': ProjectChangeOrder.statusSent,
      'sent_at': '2026-09-20T10:00:00Z',
      'active_share_token': 'tok-$changeOrderId',
    });
    _replace(next);
    return next;
  }

  @override
  Future<void> sendChangeOrderEmail(String projectId, String changeOrderId, ChangeOrderEmailInput input) async {
    await _write('sendChangeOrderEmail:$changeOrderId');
    emails.add(input);
  }

  @override
  Future<ProjectChangeOrder> reviseChangeOrder(String projectId, String changeOrderId) async {
    await _write('reviseChangeOrder:$changeOrderId');
    final co = store.firstWhere((c) => c.id == changeOrderId);
    _replace(_copy(co, {'status': ProjectChangeOrder.statusSuperseded, 'active_share_token': null}));
    final seq = store.length + 1;
    final revised = _copy(co, {
      'id': 'co-rev',
      'sequence_no': seq,
      'change_order_no': 'EK-${seq.toString().padLeft(3, '0')}',
      'status': ProjectChangeOrder.statusDraft,
      'sent_at': null,
      'rejected_at': null,
      'responded_at': null,
      'active_share_token': null,
      'supersedes_change_order_id': changeOrderId,
    });
    store.add(revised);
    return revised;
  }

  @override
  Future<ProjectChangeOrder> cancelChangeOrder(String projectId, String changeOrderId) async {
    await _write('cancelChangeOrder:$changeOrderId');
    final co = store.firstWhere((c) => c.id == changeOrderId);
    final next = _copy(co, {
      'status': ProjectChangeOrder.statusCancelled,
      'cancelled_at': '2026-09-20T10:00:00Z',
      'active_share_token': null,
    });
    _replace(next);
    return next;
  }

  @override
  Future<ProjectChangeOrder> recordChangeOrderDecision(
    String projectId,
    String changeOrderId, {
    required bool approved,
    String note = '',
  }) async {
    await _write('recordChangeOrderDecision:$changeOrderId');
    decisions.add((id: changeOrderId, approved: approved, note: note));
    final co = store.firstWhere((c) => c.id == changeOrderId);
    final next = _copy(co, {
      'status': approved ? ProjectChangeOrder.statusApproved : ProjectChangeOrder.statusRejected,
      'responded_at': '2026-09-21T09:00:00Z',
      approved ? 'approved_at' : 'rejected_at': '2026-09-21T09:00:00Z',
      'decision_recorded_by': 'owner',
      'decision_recorded_by_name': 'Ayşe Yönetici',
      'decision_note': note,
    });
    _replace(next);
    return next;
  }

  @override
  Future<ContractValueSummary> contractValueSummary(String projectId) async {
    calls.add('summary');
    return summary;
  }

  @override
  Future<List<ChangeOrderEvent>> changeOrderEvents(String projectId) async {
    calls.add('events');
    return [...events]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }
}

/// Model -> backend JSON (yalnızca sahte depo içindir).
Map<String, dynamic> _toJson(ProjectChangeOrder co) => {
      'id': co.id,
      'project_id': co.projectId,
      'sequence_no': co.sequenceNo,
      'change_order_no': co.changeOrderNo,
      'change_type': co.changeType,
      'title': co.title,
      'description': co.description,
      'status': co.status,
      'subtotal': co.subtotal,
      'vat_rate': co.vatRate,
      'vat_amount': co.vatAmount,
      'grand_total': co.grandTotal,
      'currency': co.currency,
      'internal_notes': co.internalNotes,
      'customer_notes': co.customerNotes,
      'created_at': co.createdAt,
      'updated_at': co.updatedAt,
      'sent_at': co.sentAt,
      'responded_at': co.respondedAt,
      'approved_at': co.approvedAt,
      'rejected_at': co.rejectedAt,
      'cancelled_at': co.cancelledAt,
      'supersedes_change_order_id': co.supersedesChangeOrderId,
      'active_share_token': co.activeShareToken,
      'decision_recorded_by': co.decisionRecordedBy,
      'decision_recorded_by_name': co.decisionRecordedByName,
      'decision_note': co.decisionNote,
      'items': [
        for (final it in co.items)
          {
            'id': it.id,
            'product_id': it.productId,
            'description': it.description,
            'quantity': it.quantity,
            'unit': it.unit,
            'unit_price': it.unitPrice,
            'line_total': it.lineTotal,
            'sort_order': it.sortOrder,
            'estimated_unit_cost': it.estimatedUnitCost,
            'estimated_cost': it.estimatedCost,
          },
      ],
    };

class FakeAuth extends AuthController {
  FakeAuth(this._user);
  final User _user;

  @override
  Future<User?> build() async => _user;
}

/// Gerçek uygulamadaki gibi: `/projeler/:id` altında `contractCoRoutes`.
/// Proje detayının kendisi yerine sade bir yer tutucu (bu testlerin konusu
/// değil); `projectPage` verilirse `/projeler/:id` onu çizer (gömülü
/// sekme testleri).
Widget buildContractCoApp({
  required User user,
  required FakeContractCoRepository repo,
  required String initialLocation,
  Project? project,
  ThemeData? theme,
  Widget Function(String projectId)? projectPage,
}) {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/projeler',
        builder: (_, _) => const Scaffold(body: Center(child: Text('Projeler'))),
        routes: [
          GoRoute(
            path: ':id',
            builder: (_, state) =>
                projectPage?.call(state.pathParameters['id']!) ??
                const Scaffold(body: Center(child: Text('Proje Detayı'))),
            routes: contractCoRoutes,
          ),
        ],
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      authControllerProvider.overrideWith(() => FakeAuth(user)),
      contractCoRepositoryProvider.overrideWithValue(repo),
      projectDetailProvider.overrideWith((ref, id) async => project ?? sampleProject()),
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

/// Golden testleri için uygulama fontları (Inter + MaterialIcons).
Future<void> loadAppFonts() async {
  final manifest = json.decode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

/// Uygulama teması + AppBar başlığı ve düğme etiketlerine Inter (temada
/// fontFamily taşımayan stiller test motorunda kutu glife düşer).
ThemeData goldenTheme() {
  final theme = AppTheme.light();
  const inter = TextStyle(fontFamily: 'Inter');
  final elevated = theme.elevatedButtonTheme.style;
  return theme.copyWith(
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Inter'),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: elevated?.copyWith(
        textStyle: WidgetStatePropertyAll(
          (elevated.textStyle?.resolve(const {}) ?? const TextStyle()).merge(inter),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: (theme.outlinedButtonTheme.style ?? const ButtonStyle()).copyWith(
        textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: (theme.textButtonTheme.style ?? const ButtonStyle()).copyWith(
        textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600)),
      ),
    ),
  );
}

/// Sahibin gördüğü Finans grubu çipleri (proje detayıyla aynı sıra/etiket).
const kFinansChips = [
  (alt: 'finans', label: 'Masraf & Tahsilat'),
  (alt: 'sozlesme', label: 'Sözleşme'),
  (alt: 'odeme-plani', label: 'Ödeme Planı'),
  (alt: 'faturalar', label: 'Faturalar'),
  (alt: 'taseron-odemeleri', label: 'Taşeron Ödemeleri'),
  (alt: 'ek-isler', label: 'Ek İşler'),
  (alt: 'maliyet', label: 'Maliyet Kontrolü'),
];

/// Proje detayının Finans grubunu taklit eden sayfa: üstte GERÇEK alt görünüm
/// çip şeridi ([selected] seçili), altında `Expanded` içinde bölüm gövdesi.
Widget embeddedSectionPage(Widget body, {String selected = 'finans'}) => Scaffold(
      appBar: AppBar(title: const Text('Kadıköy Ofis Tadilatı')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProjectSubViewBar(items: kFinansChips, selected: selected, onSelected: (_) {}),
          Expanded(child: body),
        ],
      ),
    );
