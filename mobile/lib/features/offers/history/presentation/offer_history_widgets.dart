import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/status_badge.dart';
import '../domain/offer_history.dart';

/// Teklif geçmişinin ortak parçaları -- hem teklif detayındaki bölüm
/// (`OfferHistorySection`) hem tam ekran (`OfferHistoryScreen`) kullanır.

Color _toneColor(OfferEventTone tone) => switch (tone) {
      OfferEventTone.success => AppColors.success,
      OfferEventTone.danger => AppColors.danger,
      OfferEventTone.muted => AppColors.textMuted,
      OfferEventTone.info => AppColors.info,
      OfferEventTone.normal => AppColors.textPrimary,
    };

Color _dotColor(OfferEventTone tone) =>
    tone == OfferEventTone.normal ? AppColors.textMuted.withValues(alpha: 0.6) : _toneColor(tone);

/// Web özet satırı: "N görüntülenme · ilk … · son …". Görüntüleme yoksa
/// hiç çizilmez.
class OfferViewsSummary extends StatelessWidget {
  const OfferViewsSummary({super.key, required this.views});

  final List<OfferEvent> views;

  @override
  Widget build(BuildContext context) {
    if (views.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.info.withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.visibility_outlined, size: 16, color: AppColors.info),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: AppTypography.helper.copyWith(height: 1.4),
                children: [
                  TextSpan(
                    text: '${views.length} görüntülenme',
                    style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700),
                  ),
                  TextSpan(text: ' · ilk ${offerFullStamp(views.first.createdAt)}'),
                  TextSpan(text: ' · son ${offerFullStamp(views.last.createdAt)}'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Olay zaman çizelgesi (web sırası: en eski üstte). Solda saat damgası,
/// ortada tonlu nokta + çizgi, sağda metin.
class OfferEventTimeline extends StatelessWidget {
  const OfferEventTimeline({super.key, required this.events, required this.history});

  final List<OfferEvent> events;
  final OfferHistory history;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
      child: Column(
        children: [
          for (var i = 0; i < events.length; i++)
            _EventRow(
              event: events[i],
              label: offerEventLabel(events[i], history.revisionNoOf(events[i].revisionId)),
              isLast: i == events.length - 1,
            ),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.label, required this.isLast});

  final OfferEvent event;
  final String label;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final tone = offerEventTone(event.eventType);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 84,
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                offerShortStamp(event.createdAt),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                style: AppTypography.helper.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
          ),
          SizedBox(
            width: 18,
            child: Column(
              children: [
                const SizedBox(height: 4),
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(color: _dotColor(tone), shape: BoxShape.circle),
                ),
                if (!isLast)
                  Expanded(child: Container(width: 1.5, margin: const EdgeInsets.only(top: 3), color: AppColors.border)),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Text(
                label,
                style: AppTypography.body.copyWith(
                  fontSize: 13.5,
                  color: _toneColor(tone),
                  fontWeight: tone == OfferEventTone.normal ? FontWeight.w500 : FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tek e-posta kaydı: alıcı + Gönderildi/Başarısız, konu · Revizyon N ·
/// tarih, hata mesajı (web "Mail Geçmişi" satırı).
class OfferEmailLogTile extends StatelessWidget {
  const OfferEmailLogTile({super.key, required this.log, required this.revisionNo});

  final OfferEmailLog log;
  final int? revisionNo;

  @override
  Widget build(BuildContext context) {
    final meta = [
      if (log.subject.isNotEmpty) log.subject,
      if (revisionNo != null) 'Revizyon $revisionNo',
      offerFullStamp(log.sentAt),
    ].join(' · ');
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Alıcı (satırın en önemli bilgisi) tam genişlikte: durum rozeti
          // yanında 360 dp'de "satinalma@modayapi.co..." diye kesiliyordu.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                log.isSent ? Icons.mark_email_read_outlined : Icons.mark_email_unread_outlined,
                size: 18,
                color: log.isSent ? AppColors.success : AppColors.danger,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(log.recipient, style: AppTypography.cardTitle)),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              log.isSent
                  ? const StatusBadge(label: 'Gönderildi', tone: StatusTone.success)
                  : const StatusBadge(label: 'Başarısız', tone: StatusTone.danger),
              Text(meta, style: AppTypography.metadata),
            ],
          ),
          if (log.errorMessage.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(log.errorMessage, style: AppTypography.helper.copyWith(color: AppColors.danger)),
          ],
        ],
      ),
    );
  }
}
