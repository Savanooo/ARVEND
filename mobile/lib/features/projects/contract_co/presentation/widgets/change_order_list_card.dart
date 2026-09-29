import 'package:flutter/material.dart';

import '../../../../../core/theme/app_typography.dart';
import '../../../../../core/widgets/app_list_card.dart';
import '../../../../../core/widgets/status_badge.dart';
import '../../domain/project_change_order.dart';
import 'contract_co_ui.dart';

/// Ek iş liste satırı: başlık; altında "EK-003 · tür · ilgili tarih"; sağda
/// durum rozeti ve işaretli tutar (ek iş +yeşil, eksiltme −kırmızı). Hem "Ek İşler"
/// listesinde hem Sözleşme ekranının "Bu Sözleşmeyi Değiştiren Ek İşler"
/// bölümünde aynı görünüm. Tutar içerdiği için yalnızca
/// `projects.finance.read` sahibine çizilir (liste ucu zaten bunu ister).
class ChangeOrderListCard extends StatelessWidget {
  const ChangeOrderListCard({super.key, required this.changeOrder, this.onTap});

  final ProjectChangeOrder changeOrder;
  final VoidCallback? onTap;

  /// Durumun en anlamlı tarihi -- satırda ayrıca "ne zaman" sorusunu
  /// cevaplar (rozet zaten "ne" olduğunu söyler).
  static String subtitleFor(ProjectChangeOrder co) {
    final date = switch (co.status) {
      ProjectChangeOrder.statusSent => co.sentAt,
      ProjectChangeOrder.statusApproved => co.approvedAt ?? co.respondedAt,
      ProjectChangeOrder.statusRejected => co.rejectedAt ?? co.respondedAt,
      ProjectChangeOrder.statusCancelled => co.cancelledAt,
      _ => co.createdAt,
    };
    final when = (date == null || date.isEmpty) ? null : formatDateTr(date);
    return [co.changeOrderNo, co.typeLabel, ?when].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final co = changeOrder;
    return AppListCard(
      // Numara alt satırda: 360 dp'de "EK-003 — ..." başlığın çoğunu yiyordu.
      title: co.title.isEmpty ? co.changeOrderNo : co.title,
      subtitle: subtitleFor(co),
      onTap: onTap,
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          StatusRegistry.build(co.status, StatusRegistry.changeOrder),
          const SizedBox(height: 4),
          SignedMoneyText(
            co.signedTotal,
            currency: co.currency,
            style: AppTypography.metadata.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
