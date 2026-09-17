import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/projects_providers.dart';
import '../domain/subcontract.dart';
import 'subcontract_payment_form_sheet.dart';

/// Sprint 5 — Taşeron Sözleşmesi detayı. SOV/hakediş mobilde YALNIZCA OKUMA
/// (değişiklik emri onayı gibi hassas karar anları web'de kalır); ödeme
/// kaydı (GERÇEK nakit çıkışı) TEK yazma aksiyonudur -- backend Sprint 5
/// follow-up'ın (migration 0039) mobildeki karşılığı.
///
/// current_value/certified_to_date/remaining_commitment (taahhüt ekseni) ile
/// paid_to_date/remaining_payable (nakit ekseni) BİLİNÇLİ OLARAK AYRI
/// gösterilir -- sertifikasyon ödeme DEĞİLDİR, ikisi TEK bir rakamda
/// BİRLEŞTİRİLMEZ (bkz. backend SubcontractValueSummary yorumu).
class SubcontractDetailScreen extends ConsumerWidget {
  const SubcontractDetailScreen({super.key, required this.projectId, required this.subcontractId});
  final String projectId;
  final String subcontractId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, subcontractId: subcontractId);
    final detailAsync = ref.watch(subcontractDetailProvider(args));

    return Scaffold(
      appBar: AppBar(
        title: detailAsync.maybeWhen(
          data: (d) => Text(d.subcontract.subcontractNo),
          orElse: () => const Text('Taşeron Sözleşmesi'),
        ),
      ),
      body: AsyncStateView(
        value: detailAsync,
        onRetry: () async => ref.invalidate(subcontractDetailProvider(args)),
        data: (context, detail) => _SubcontractDetailBody(projectId: projectId, subcontractId: subcontractId, detail: detail),
      ),
    );
  }
}

class _SubcontractDetailBody extends ConsumerWidget {
  const _SubcontractDetailBody({required this.projectId, required this.subcontractId, required this.detail});
  final String projectId;
  final String subcontractId;
  final ({Subcontract subcontract, List<SubcontractItem> items, SubcontractValue value}) detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final args = (projectId: projectId, subcontractId: subcontractId);
    final paymentsAsync = ref.watch(subcontractPaymentsProvider(args));
    final claimsAsync = ref.watch(subcontractProgressClaimsProvider(args));
    final sc = detail.subcontract;
    final value = detail.value;

    void refreshAll() {
      ref.invalidate(subcontractDetailProvider(args));
      ref.invalidate(subcontractPaymentsProvider(args));
      // Yeni-modül taşeron ödemeleri financial-summary/cost-control'e
      // AKAR (migration 0039 follow-up) -- proje özetinin bayatlamaması
      // için bunlar da tazelenir (Tahsilat akışıyla AYNI ilke).
      ref.invalidate(projectFinancialSummaryProvider(projectId));
      ref.invalidate(projectCostControlProvider(projectId));
    }

    return RefreshIndicator(
      onRefresh: () async {
        refreshAll();
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              StatusRegistry.build(sc.status, StatusRegistry.subcontract),
              Text(Formatters.money(value.currentValue, currency: sc.currency),
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sc.supplierName ?? sc.supplierCode ?? '-', style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (sc.title.isNotEmpty) Text(sc.title, style: const TextStyle(color: Colors.grey)),
                  const Divider(height: 20),
                  _Row('Sözleşme Bedeli', Formatters.money(sc.originalAmount, currency: sc.currency)),
                  _Row('Güncel Değer', Formatters.money(value.currentValue, currency: sc.currency)),
                  if (sc.retentionPercent != null)
                    _Row('Hakediş Kesintisi (Retention)', '%${sc.retentionPercent!.toStringAsFixed(2)}'),
                  if (sc.advanceAmount != null)
                    _Row('Avans Tutarı', Formatters.money(sc.advanceAmount!, currency: sc.currency)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Taahhüt ekseni (SOV bazlı, hakediş sertifikasyonuyla değişir).
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Taahhüt', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 4),
                  _Row('Sertifika Edilen (Hakediş)', Formatters.money(value.certifiedToDate, currency: sc.currency)),
                  _Row('Kalan Taahhüt', Formatters.money(value.remainingCommitment, currency: sc.currency)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Nakit ekseni (GERÇEK ödeme, sertifikasyondan BAĞIMSIZ).
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Ödeme', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 4),
                  _Row('Ödenen', Formatters.money(value.paidToDate, currency: sc.currency)),
                  _Row(
                    'Ödenecek Kalan (Sertifika − Ödenen)',
                    Formatters.money(value.remainingPayable, currency: sc.currency),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('SOV / İş Kalemleri', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (detail.items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Kalem yok.', style: TextStyle(color: Colors.grey)),
            )
          else
            ...detail.items.map((item) => Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    title: Text(item.description, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: item.unit.isNotEmpty && item.quantity != null
                        ? Text('${item.quantity} ${item.unit}')
                        : null,
                    trailing: Text(Formatters.money(item.originalAmount, currency: sc.currency),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                )),
          const SizedBox(height: 16),
          const Text('Hakedişler', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          AsyncStateView(
            value: claimsAsync,
            onRetry: () async => ref.invalidate(subcontractProgressClaimsProvider(args)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Henüz hakediş yok.', style: TextStyle(color: Colors.grey)),
            ),
            data: (context, claims) => Column(
              children: claims
                  .map((c) => Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          title: Text(c.claimNumber),
                          subtitle: StatusRegistry.build(c.status, StatusRegistry.progressClaim),
                          trailing: Text(Formatters.money(c.netPayable, currency: sc.currency),
                              style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Ödemeler', style: TextStyle(fontWeight: FontWeight.w700)),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Ödeme Ekle'),
                onPressed: () async {
                  final created = await showSubcontractPaymentFormSheet(
                    context,
                    projectId,
                    subcontractId,
                    currency: sc.currency,
                  );
                  if (created != null) refreshAll();
                },
              ),
            ],
          ),
          AsyncStateView(
            value: paymentsAsync,
            onRetry: () async => ref.invalidate(subcontractPaymentsProvider(args)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Henüz ödeme kaydı yok.', style: TextStyle(color: Colors.grey)),
            ),
            data: (context, payments) => Column(
              children: payments
                  .map((p) => Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          title: Text(p.paymentMethod.isEmpty ? 'Ödeme' : p.paymentMethod),
                          subtitle: Text(
                            [
                              Formatters.date(p.paidDate),
                              if (p.description.isNotEmpty) p.description,
                              if (p.referenceNo.isNotEmpty) p.referenceNo,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            Formatters.money(p.amount, currency: sc.currency),
                            style: TextStyle(
                              decoration: p.isVoided ? TextDecoration.lineThrough : null,
                              fontWeight: FontWeight.w600,
                              color: Colors.green.shade700,
                            ),
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(label, style: const TextStyle(color: Colors.grey))),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
