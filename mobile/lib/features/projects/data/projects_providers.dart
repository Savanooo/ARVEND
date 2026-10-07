import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../domain/procurement.dart';
import '../domain/project.dart';
import '../domain/subcontract.dart';
import 'projects_repository.dart';

final projectsRepositoryProvider =
    Provider<ProjectsRepository>((ref) => ProjectsRepository(ref.watch(apiClientProvider)));

/// Proje listesi süzgeci: durum (null = tümü) + arama metni. Arama
/// SUNUCUDA yapılır (`GET /projects?q=` -- ad, proje no, müşteri adı):
/// eskiden yalnızca ilk 50 proje çekilip onların içinde aranıyordu, 51.
/// proje hiç bulunamıyordu.
typedef ProjectsListQuery = ({String? status, String q});

/// Sayfa sayfa büyüyen proje listesi. `total` backend'in toplamıdır; boş
/// bir sayfa gelirse (liste bu arada kısaldı) `reachedEnd` ile durulur.
class ProjectsPage {
  const ProjectsPage({
    required this.projects,
    required this.total,
    required this.page,
    this.reachedEnd = false,
    this.loadingMore = false,
    this.loadMoreError,
  });

  final List<Project> projects;
  final int total;
  final int page;
  final bool reachedEnd;
  final bool loadingMore;
  final Object? loadMoreError;

  bool get hasMore => !reachedEnd && projects.length < total;

  ProjectsPage copyWith({bool? loadingMore, Object? loadMoreError, bool clearError = false}) => ProjectsPage(
        projects: projects,
        total: total,
        page: page,
        reachedEnd: reachedEnd,
        loadingMore: loadingMore ?? this.loadingMore,
        loadMoreError: clearError ? null : (loadMoreError ?? this.loadMoreError),
      );
}

class ProjectsListNotifier extends AutoDisposeFamilyAsyncNotifier<ProjectsPage, ProjectsListQuery> {
  static const pageSize = 50;

  // Yenileme (invalidate) build'i yeniden çalıştırır: o sırada uçan bir
  // "daha fazla" isteği eski listeyi geri yazmasın diye nesil sayılır.
  int _generation = 0;
  bool _alive = true;

  Future<({List<Project> projects, int total})> _fetch(int page) => ref
      .read(projectsRepositoryProvider)
      .list(status: arg.status, q: arg.q, page: page, limit: pageSize);

  @override
  Future<ProjectsPage> build(ProjectsListQuery arg) async {
    _generation++;
    _alive = true;
    ref.onDispose(() => _alive = false);
    ref.watch(projectsRepositoryProvider);
    final first = await _fetch(1);
    return ProjectsPage(projects: first.projects, total: first.total, page: 1, reachedEnd: first.projects.isEmpty);
  }

  /// [auto]: kaydırma dinleyicisinden gelen çağrı. Son istek hata verdiyse
  /// otomatik çağrı YENİDEN DENEMEZ (çevrimdışıyken her kaydırma yeni istek
  /// atmasın); yeniden deneme yalnızca "Tekrar Dene" ile.
  Future<void> loadMore({bool auto = false}) async {
    final current = state.valueOrNull;
    if (current == null || current.loadingMore || !current.hasMore || state.isLoading) return;
    if (auto && current.loadMoreError != null) return;
    final generation = _generation;
    bool stale() => !_alive || generation != _generation;
    state = AsyncData(current.copyWith(loadingMore: true, clearError: true));
    try {
      final next = await _fetch(current.page + 1);
      if (stale()) return;
      // Sayfalar arasında liste değişirse (OFFSET kayması) aynı proje iki
      // kez görünmesin.
      final seen = {for (final p in current.projects) p.id};
      state = AsyncData(ProjectsPage(
        projects: [...current.projects, for (final p in next.projects) if (seen.add(p.id)) p],
        total: next.total,
        page: current.page + 1,
        reachedEnd: next.projects.isEmpty,
      ));
    } catch (e) {
      if (stale()) return;
      state = AsyncData(current.copyWith(loadingMore: false, loadMoreError: e));
    }
  }
}

final projectsListProvider =
    AsyncNotifierProvider.autoDispose.family<ProjectsListNotifier, ProjectsPage, ProjectsListQuery>(
  ProjectsListNotifier.new,
);

/// Görev/plan formunun "kime" seçicisi (ücretsiz personel listesi; proje
/// yöneticisinde employees.read olmadığı için ayrı uç).
final projectAssigneesProvider = FutureProvider.autoDispose.family<List<Assignee>, String>(
  (ref, projectId) => ref.watch(projectsRepositoryProvider).assignees(projectId),
);

final projectDetailProvider = FutureProvider.autoDispose.family<Project, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).get(id),
);

/// Müşteri detay ekranının "Projeler" bölümü için -- backend'in zaten
/// var olan `GET /projects?customer_id=` filtresini kullanır (bkz. backend
/// Phase 1 doğrulaması: `projects.customer_id` gerçek, canlı sorgulanabilir
/// bir FK'dır), N+1 YOKTUR. Finans alanları (contract/collected/remaining)
/// bu liste sorgusunda ZATEN dolu gelir -- ayrı bir hesaplama İCAT EDİLMEZ.
final customerProjectsProvider =
    FutureProvider.autoDispose.family<({List<Project> projects, int total}), String>(
  (ref, customerId) => ref.watch(projectsRepositoryProvider).list(customerId: customerId, limit: 200),
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

final projectOperationsSummaryProvider = FutureProvider.autoDispose.family<ProjectOperationsSummary, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).operationsSummary(id),
);

final projectPhotosProvider = FutureProvider.autoDispose.family<List<ProjectPhoto>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).photos(id),
);

final projectFilesProvider = FutureProvider.autoDispose.family<List<ProjectFile>, String>(
  (ref, id) => ref.watch(projectsRepositoryProvider).files(id),
);

typedef ProjectPhotoKey = ({String projectId, String photoId});

/// Kimlik doğrulamalı bayt önbelleği -- Riverpod'un family önbelleği
/// aynı (projectId, photoId) için thumbnail'i ve tam-ekran görüntüleyiciyi
/// İKİNCİ bir ağ isteği ATMADAN paylaşır.
final projectPhotoBytesProvider = FutureProvider.autoDispose.family<Uint8List, ProjectPhotoKey>(
  (ref, key) => ref.watch(projectsRepositoryProvider).photoBytes(key.projectId, key.photoId),
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
