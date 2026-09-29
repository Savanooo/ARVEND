import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/errors/api_exception.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_section_header.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../data/offer_history_providers.dart';
import '../domain/offer_history.dart';
import '../offer_history_paths.dart';
import 'offer_history_widgets.dart';

const kOfferHistoryNoAccessText = 'Teklif geçmişini görüntüleme yetkin yok. Yöneticinden rolüne "Teklifleri '
    'görüntüleme" iznini eklemesini isteyebilirsin.';

/// Teklif detayına ("Revizyon Geçmişi"nin altına) eklenecek bölüm: web
/// `ActivityTimeline` -- "Aktivite / Zaman Çizelgesi" (son [previewEvents]
/// olay) ve varsa "Mail Geçmişi" (son [previewEmails] kayıt). Tamamı
/// "Tümünü Gör" ile tam ekranda (`/teklifler/:id/gecmis`). Kendi
/// kaydırıcısı YOK -- detayın `ListView`'ına doğrudan çocuk olarak girer.
/// 403'te çökmez, kısa bir "yetkin yok" notu gösterir.
class OfferHistorySection extends ConsumerWidget {
  const OfferHistorySection({super.key, required this.offerId, this.previewEvents = 5, this.previewEmails = 3});

  final String offerId;
  final int previewEvents;
  final int previewEmails;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(offerHistoryProvider(offerId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSectionHeader(title: 'Aktivite / Zaman Çizelgesi'),
        const SizedBox(height: AppSpacing.sm),
        historyAsync.when(
          loading: () => const SizedBox(height: 96, child: LoadingState()),
          error: (e, _) => e is ApiException && e.isForbidden
              ? const ReadOnlyNotice(kOfferHistoryNoAccessText)
              : ErrorState(error: e, onRetry: () async => ref.invalidate(offerHistoryProvider(offerId))),
          data: (h) => _body(context, h),
        ),
      ],
    );
  }

  Widget _body(BuildContext context, OfferHistory h) {
    // Mobildeki tüm zaman çizelgeleri gibi EN YENİ ÜSTTE (proje Aktivite,
    // Ek İş olayları; altındaki Mail Geçmişi de yeniden eskiye). Depo
    // eskiden yeniye sıralar.
    final shownEvents = h.events.reversed.take(previewEvents).toList();
    final shownEmails = h.emailLogs.take(previewEmails).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (h.views.isNotEmpty) ...[
          OfferViewsSummary(views: h.views),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (h.events.isEmpty)
          const OfferHistoryEmptyNote('Henüz kayıtlı bir olay yok.')
        else ...[
          if (h.events.length > previewEvents)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text('Son $previewEvents olay gösteriliyor.', style: AppTypography.helper),
            ),
          OfferEventTimeline(events: shownEvents, history: h),
          if (h.events.length > previewEvents)
            _SeeAllButton(
              label: 'Tümünü Gör (${h.events.length})',
              onPressed: () => context.push(offerHistoryPath(offerId)),
            ),
        ],
        if (h.emailLogs.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xl),
          const AppSectionHeader(title: 'Mail Geçmişi'),
          const SizedBox(height: AppSpacing.sm),
          for (final log in shownEmails) OfferEmailLogTile(log: log, revisionNo: h.revisionNoOf(log.revisionId)),
          if (h.emailLogs.length > previewEmails)
            _SeeAllButton(
              label: 'Tümünü Gör (${h.emailLogs.length})',
              onPressed: () => context.push(offerHistoryPath(offerId, emails: true)),
            ),
        ],
      ],
    );
  }
}

/// Önizlemenin altındaki "Tümünü Gör (N)" bağlantısı (sağa yaslı).
class _SeeAllButton extends StatelessWidget {
  const _SeeAllButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: onPressed,
        iconAlignment: IconAlignment.end,
        icon: const Icon(Icons.chevron_right, size: 18),
        label: Text(label),
      ),
    );
  }
}

/// Liste içi küçük boş durum notu.
class OfferHistoryEmptyNote extends StatelessWidget {
  const OfferHistoryEmptyNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(text, style: AppTypography.metadata, textAlign: TextAlign.center),
    );
  }
}
