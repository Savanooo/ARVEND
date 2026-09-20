import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/procurement.dart';
import '../domain/project.dart';
import '../domain/subcontract.dart';
import 'projects_repository.dart';

final projectsRepositoryProvider =
    Provider<ProjectsRepository>((ref) => ProjectsRepository(ref.watch(apiClientProvider)));

final projectsListProvider =
    FutureProvider.autoDispose.family<({List<Project> projects, int total}), String?>(
  (ref, status) => ref.watch(projectsRepositoryProvider).list(status: status),
);

final projectDetailProvider = FutureProvider.autoDispose.family<Project, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).get(id),
);

final projectFinancialSummaryProvider = FutureProvider.autoDispose.family<FinancialSummary, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).financialSummary(id),
);

final projectExpensesProvider = FutureProvider.autoDispose.family<List<Expense>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).expenses(id),
);

final projectCollectionsProvider = FutureProvider.autoDispose.family<List<Collection>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).collections(id),
);

final projectTasksProvider = FutureProvider.autoDispose.family<List<ProjectTask>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).tasks(id),
);

final projectPhotosProvider = FutureProvider.autoDispose.family<List<ProjectPhoto>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).photos(id),
);

final projectFilesProvider = FutureProvider.autoDispose.family<List<ProjectFile>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).files(id),
);

final projectCostControlProvider = FutureProvider.autoDispose
    .family<({CostControlSummary summary, List<CostControlLine> lines}), String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).costControl(id),
);

final projectChangeOrdersProvider = FutureProvider.autoDispose.family<List<ChangeOrder>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).changeOrders(id),
);

final projectPurchaseRequestsProvider = FutureProvider.autoDispose.family<List<PurchaseRequest>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).purchaseRequests(id),
);

final purchaseRequestDetailProvider = FutureProvider.autoDispose.family<
    ({PurchaseRequest request, List<PurchaseRequestItem> items}),
    ({String projectId, String prId})>(
  (ref, args) => ref.watch(projectsRepositoryProvider).purchaseRequestDetail(args.projectId, args.prId),
);

final projectPurchaseOrdersProvider = FutureProvider.autoDispose.family<List<PurchaseOrder>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).purchaseOrders(id),
);

final purchaseOrderDetailProvider = FutureProvider.autoDispose.family<
    ({PurchaseOrder order, List<PurchaseOrderItem> items, List<Commitment> commitments}),
    ({String projectId, String poId})>(
  (ref, args) => ref.watch(projectsRepositoryProvider).purchaseOrderDetail(args.projectId, args.poId),
);

// ---------- P3: RFQ / Teklif / Karşılaştırma ----------

final projectRFQsProvider = FutureProvider.autoDispose.family<List<RFQ>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).rfqs(id),
);

final rfqDetailProvider = FutureProvider.autoDispose.family<
    ({RFQ rfq, List<RFQItem> items, List<RFQSupplier> suppliers}),
    ({String projectId, String rfqId})>(
  (ref, args) => ref.watch(projectsRepositoryProvider).rfqDetail(args.projectId, args.rfqId),
);

final rfqQuotationsProvider = FutureProvider.autoDispose
    .family<List<Quotation>, ({String projectId, String rfqId})>(
  (ref, args) => ref.watch(projectsRepositoryProvider).quotations(args.projectId, args.rfqId),
);

final quotationDetailProvider = FutureProvider.autoDispose.family<
    ({Quotation quotation, List<QuotationItem> items}),
    ({String projectId, String rfqId, String quotationId})>(
  (ref, args) => ref.watch(projectsRepositoryProvider).quotationDetail(args.projectId, args.rfqId, args.quotationId),
);

final bidComparisonProvider = FutureProvider.autoDispose.family<
    ({List<BidComparisonRow> rows, List<Quotation> quotations}),
    ({String projectId, String rfqId})>(
  (ref, args) => ref.watch(projectsRepositoryProvider).bidComparison(args.projectId, args.rfqId),
);

final projectSubcontractsProvider = FutureProvider.autoDispose.family<List<Subcontract>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).subcontracts(id),
);

final subcontractDetailProvider = FutureProvider.autoDispose.family<
    ({Subcontract subcontract, List<SubcontractItem> items, SubcontractValue value}),
    ({String projectId, String subcontractId})>(
  (ref, args) => ref.watch(projectsRepositoryProvider).subcontractDetail(args.projectId, args.subcontractId),
);

final subcontractPaymentsProvider = FutureProvider.autoDispose
    .family<List<SubcontractPayment>, ({String projectId, String subcontractId})>(
  (ref, args) => ref.watch(projectsRepositoryProvider).subcontractPayments(args.projectId, args.subcontractId),
);

final subcontractProgressClaimsProvider = FutureProvider.autoDispose
    .family<List<ProgressClaim>, ({String projectId, String subcontractId})>(
  (ref, args) => ref.watch(projectsRepositoryProvider).subcontractProgressClaims(args.projectId, args.subcontractId),
);

final projectNotesProvider = FutureProvider.autoDispose.family<List<ProjectNote>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).notes(id),
);

/// Taşeron Sözleşmesi formundaki (Ekle/Düzenle) tedarikçi/maliyet kodu
/// seçicileri için -- organizasyon-seviyeli, projeden BAĞIMSIZ (family
/// DEĞİL).
final suppliersProvider = FutureProvider.autoDispose<List<Supplier>>(
  (ref) => ref.watch(projectsRepositoryProvider).suppliers(),
);

final orgCostCodesProvider = FutureProvider.autoDispose<List<OrgCostCode>>(
  (ref) => ref.watch(projectsRepositoryProvider).costCodes(),
);

// ---------- P2: Hakediş (Progress Claim) ----------

final progressClaimDetailProvider = FutureProvider.autoDispose.family<
    ({ProgressClaim claim, List<ProgressClaimItem> items}),
    ({String projectId, String claimId})>(
  (ref, args) => ref.watch(projectsRepositoryProvider).progressClaimDetail(args.projectId, args.claimId),
);

// ---------- P2: Taşeron Değişiklik Emri (Subcontract Change Order) ----------

final subcontractChangeOrdersProvider = FutureProvider.autoDispose
    .family<List<SubcontractChangeOrder>, ({String projectId, String subcontractId})>(
  (ref, args) => ref.watch(projectsRepositoryProvider).subcontractChangeOrders(args.projectId, args.subcontractId),
);

final subcontractChangeOrderDetailProvider = FutureProvider.autoDispose.family<
    ({SubcontractChangeOrder changeOrder, List<SubcontractChangeOrderItem> items}),
    ({String projectId, String changeOrderId})>(
  (ref, args) =>
      ref.watch(projectsRepositoryProvider).subcontractChangeOrderDetail(args.projectId, args.changeOrderId),
);
