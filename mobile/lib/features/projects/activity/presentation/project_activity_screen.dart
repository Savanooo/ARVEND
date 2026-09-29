import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/errors/api_exception.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../data/projects_providers.dart';
import '../data/project_activity_providers.dart';
import '../domain/project_event.dart';

const _kNoAccessText =
    'Bu projenin hareketlerini görüntüleme yetkin yok. Yöneticinden seni projeye eklemesini isteyebilirsin.';

/// `/projeler/:id/aktivite` -- web proje sayfasının "Aktivite" sekmesi
/// ("Aktivite Geçmişi"). AppBar'daki geçmiş simgesi ve Özet'teki "Tüm
/// hareketler" bağlantısı buraya açılır.
class ProjectActivityScreen extends StatelessWidget {
  const ProjectActivityScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context) {
    return AppPageScaffold(
      title: const Text('Aktivite Geçmişi'),
      body: ProjectActivityView(projectId: projectId),
    );
  }
}

/// Olay listesi: İstanbul gününe göre gruplanmış, en yeni üstte; her satırda
/// saat, tonlu nokta, Türkçe etiket ve web'deki ayrıntı satırı (ad, fatura
/// no, durum geçişi, gerekçe). Tutarlar yalnızca `projects.finance.read`
/// sahibine gösterilir. Oturum yüklenirken istek atılmaz; 403'te "yetkin
/// yok" görünümü, çökme yok.
class ProjectActivityView extends ConsumerWidget {
  const ProjectActivityView({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (user == null && auth.isLoading) return const LoadingState();
    if (!user.can(kProjectActivityReadPermission)) {
      return const NoAccessView(message: _kNoAccessText);
    }
    final showMoney = user.can(kProjectActivityMoneyPermission);
    final currency = ref.watch(projectDetailProvider(projectId)).valueOrNull?.currency ?? 'TRY';
    final eventsAsync = ref.watch(projectActivityProvider(projectId));

    Future<void> refresh() async {
      ref.invalidate(projectActivityProvider(projectId));
      try {
        await ref.read(projectActivityProvider(projectId).future);
      } catch (_) {
        // Hata gövdede gösterilir.
      }
    }

    return RefreshIndicator(
      onRefresh: refresh,
      child: eventsAsync.when(
        loading: () => const LoadingState(),
        error: (e, _) => e is ApiException && e.isForbidden
            ? const NoAccessView(message: _kNoAccessText, scrollable: true)
            : _Scrollable(child: ErrorState(error: e, onRetry: refresh)),
        data: (events) {
          if (events.isEmpty) {
            return const _Scrollable(
              child: EmptyStateView(message: 'Henüz kayıtlı bir olay yok.', icon: Icons.history),
            );
          }
          final days = <String, List<ProjectEvent>>{};
          for (final e in events) {
            days.putIfAbsent(projectEventDayKey(e.createdAt), () => []).add(e);
          }
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xxl),
            children: [
              if (!showMoney) ...[
                const Text(
                  'Tutarlar yalnızca finans görüntüleme yetkisi olanlara gösterilir.',
                  style: AppTypography.helper,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              for (final day in days.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.xs, bottom: AppSpacing.sm),
                  // toUpperCase YOK: Dart'ın büyük harfi Türkçe değil
                  // ("Pazartesi" -> "PAZARTESI").
                  child: Text(
                    day.key.isEmpty ? 'Tarihsiz' : Formatters.longDate(day.key),
                    style: AppTypography.metadata.copyWith(fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                  ),
                ),
                AppCard(
                  margin: const EdgeInsets.only(bottom: AppSpacing.lg),
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
                  child: Column(
                    children: [
                      for (var i = 0; i < day.value.length; i++)
                        ProjectEventRow(
                          event: day.value[i],
                          detail: projectEventDetail(day.value[i], currency: currency, showMoney: showMoney),
                          isLast: i == day.value.length - 1,
                        ),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Kaydırılabilir boş/hata gövdesi -- aşağı çekerek yenileme çalışsın.
class _Scrollable extends StatelessWidget {
  const _Scrollable({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight.isFinite ? constraints.maxHeight : 0),
          child: Center(child: child),
        ),
      ),
    );
  }
}

Color _toneColor(ProjectEventTone tone) => switch (tone) {
      ProjectEventTone.success => AppColors.success,
      ProjectEventTone.danger => AppColors.danger,
      ProjectEventTone.info => AppColors.info,
      ProjectEventTone.normal => AppColors.textMuted.withValues(alpha: 0.6),
    };

/// Tek olay satırı: solda saat, ortada tonlu nokta + çizgi, sağda etiket ve
/// ayrıntı (teklif geçmişindeki zaman çizelgesiyle aynı görsel dil).
class ProjectEventRow extends StatelessWidget {
  const ProjectEventRow({super.key, required this.event, required this.detail, required this.isLast});

  final ProjectEvent event;
  final String detail;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final tone = projectEventTone(event.eventType);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 44,
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                projectEventClock(event.createdAt),
                maxLines: 1,
                softWrap: false,
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
                  decoration: BoxDecoration(color: _toneColor(tone), shape: BoxShape.circle),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    projectEventLabel(event.eventType),
                    style: AppTypography.body.copyWith(
                      fontSize: 13.5,
                      fontWeight: tone == ProjectEventTone.normal ? FontWeight.w500 : FontWeight.w600,
                      color: tone == ProjectEventTone.danger ? AppColors.danger : AppColors.textPrimary,
                    ),
                  ),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(detail, style: AppTypography.metadata, maxLines: 3, overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
