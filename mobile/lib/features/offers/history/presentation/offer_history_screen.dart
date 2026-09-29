import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/errors/api_exception.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../data/offer_history_providers.dart';
import '../domain/offer_history.dart';
import 'offer_history_section.dart';
import 'offer_history_widgets.dart';

enum OfferHistoryTab { events, emails }

/// `/teklifler/:id/gecmis[?sekme=eposta]` -- teklifin TÜM olay geçmişi
/// (web "Aktivite / Zaman Çizelgesi", en eski üstte) ve TÜM e-posta
/// kayıtları (web "Mail Geçmişi", en yeni üstte). Salt-okunur.
class OfferHistoryScreen extends ConsumerStatefulWidget {
  const OfferHistoryScreen({super.key, required this.offerId, this.initialTab = OfferHistoryTab.events});

  final String offerId;
  final OfferHistoryTab initialTab;

  @override
  ConsumerState<OfferHistoryScreen> createState() => _OfferHistoryScreenState();
}

class _OfferHistoryScreenState extends ConsumerState<OfferHistoryScreen> {
  late OfferHistoryTab _tab = widget.initialTab;

  Future<void> _refresh() async {
    ref.invalidate(offerHistoryProvider(widget.offerId));
    try {
      await ref.read(offerHistoryProvider(widget.offerId).future);
    } catch (_) {
      // Hata gövdede gösterilir.
    }
  }

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(offerHistoryProvider(widget.offerId));
    return AppPageScaffold(
      title: const Text('Teklif Geçmişi'),
      body: historyAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => e is ApiException && e.isForbidden
            ? const NoAccessView(message: kOfferHistoryNoAccessText)
            : ErrorState(error: e, onRetry: _refresh),
        data: (h) => RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
            children: [
              SegmentedButton<OfferHistoryTab>(
                segments: [
                  ButtonSegment(value: OfferHistoryTab.events, label: Text('Olaylar (${h.events.length})')),
                  ButtonSegment(value: OfferHistoryTab.emails, label: Text('Mail Geçmişi (${h.emailLogs.length})')),
                ],
                selected: {_tab},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _tab = s.first),
              ),
              const SizedBox(height: AppSpacing.lg),
              ...switch (_tab) {
                OfferHistoryTab.events => _events(h),
                OfferHistoryTab.emails => _emails(h),
              },
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _events(OfferHistory h) => [
        const Text('Aktivite / Zaman Çizelgesi', style: AppTypography.sectionTitle),
        const SizedBox(height: AppSpacing.sm),
        if (h.views.isNotEmpty) ...[OfferViewsSummary(views: h.views), const SizedBox(height: AppSpacing.sm)],
        if (h.events.isEmpty)
          const OfferHistoryEmptyNote('Henüz kayıtlı bir olay yok.')
        else
          // En yeni üstte (bkz. OfferHistorySection).
          OfferEventTimeline(events: h.events.reversed.toList(), history: h),
      ];

  List<Widget> _emails(OfferHistory h) => [
        const Text('Mail Geçmişi', style: AppTypography.sectionTitle),
        const SizedBox(height: AppSpacing.sm),
        if (h.emailLogs.isEmpty)
          const OfferHistoryEmptyNote('Bu teklif henüz e-postayla gönderilmedi.')
        else
          for (final log in h.emailLogs) OfferEmailLogTile(log: log, revisionNo: h.revisionNoOf(log.revisionId)),
      ];
}
