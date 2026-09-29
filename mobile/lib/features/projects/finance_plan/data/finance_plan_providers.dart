import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/api/api_providers.dart';
import '../../../../core/errors/api_exception.dart';
import '../../data/istanbul_day.dart';
import '../../data/projects_providers.dart';
import '../domain/finance_dates.dart';
import '../domain/payment_plan.dart';
import '../domain/project_invoice.dart';
import 'finance_plan_repository.dart';

final financePlanRepositoryProvider =
    Provider<FinancePlanRepository>((ref) => FinancePlanRepository(ref.watch(apiClientProvider)));

final projectPaymentPlanProvider = FutureProvider.autoDispose.family<PaymentPlan, String>(
  (ref, projectId) => ref.watch(financePlanRepositoryProvider).paymentPlan(projectId),
);

final projectInvoicesProvider = FutureProvider.autoDispose.family<List<ProjectInvoice>, String>(
  (ref, projectId) => ref.watch(financePlanRepositoryProvider).invoices(projectId),
);

typedef PlanItemKey = ({String projectId, String itemId});
typedef InvoiceKey = ({String projectId, String invoiceId});

/// Tekil kalem ucu YOK -- detay, liste sağlayıcısından türetilir (tek
/// kaynak; liste tazelenince detay da tazelenir, ek istek atılmaz).
final paymentPlanItemProvider = FutureProvider.autoDispose.family<PaymentPlanItem, PlanItemKey>((ref, key) async {
  final plan = await ref.watch(projectPaymentPlanProvider(key.projectId).future);
  for (final item in plan.items) {
    if (item.id == key.itemId) return item;
  }
  throw const ApiException(statusCode: 404, message: 'Ödeme planı kalemi bulunamadı.', kind: ApiErrorKind.notFound);
});

/// Tekil fatura ucu YOK -- detay, liste sağlayıcısından türetilir.
final projectInvoiceProvider = FutureProvider.autoDispose.family<ProjectInvoice, InvoiceKey>((ref, key) async {
  final invoices = await ref.watch(projectInvoicesProvider(key.projectId).future);
  for (final invoice in invoices) {
    if (invoice.id == key.invoiceId) return invoice;
  }
  throw const ApiException(statusCode: 404, message: 'Fatura bulunamadı.', kind: ApiErrorKind.notFound);
});

/// İstanbul'un bugünü -- vade ipuçları ("3 gün gecikti") ve fatura vade
/// uyarısı için. Gün değişince kendini yeniler ([trackIstanbulDay]); izleyen
/// ekran açık kaldıkça eskiden ilk günde donuyordu. Testlerde sabit bir
/// günle ezilir (deterministik golden).
final financePlanTodayProvider = Provider.autoDispose<DateTime>((ref) => trackIstanbulDay(ref, istanbulToday));

/// Ödeme planı yazıldıktan sonra tazelenecekler: plan listesi (detay da ondan
/// türer) ve finans özeti (`planned_collections`).
void invalidatePaymentPlan(ProviderContainer container, String projectId) {
  container.invalidate(projectPaymentPlanProvider(projectId));
  container.invalidate(projectFinancialSummaryProvider(projectId));
}

/// Fatura yazıldıktan sonra tazelenecekler: fatura listesi ve finans özeti
/// (`issued_invoice_total`/`paid_invoice_total`).
void invalidateInvoices(ProviderContainer container, String projectId) {
  container.invalidate(projectInvoicesProvider(projectId));
  container.invalidate(projectFinancialSummaryProvider(projectId));
}

/// 409 (proje bu arada tamamlandı/iptal edildi) sonrası proje durumu
/// tazelenir -- ekranlar kilitli görünüme geçer.
void invalidateFinancePlanProject(ProviderContainer container, String projectId) {
  container.invalidate(projectDetailProvider(projectId));
}
