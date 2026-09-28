import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_card.dart';
import '../../auth/domain/user.dart';
import '../../notifications/data/notifications_providers.dart';
import '../data/dashboard_providers.dart';
import '../domain/dashboard.dart';
import '../domain/dashboard_registry.dart';
import 'widgets/activity_card.dart';
import 'widgets/attention_card.dart';
import 'widgets/cash_flow_card.dart';
import 'widgets/dashboard_header.dart';
import 'widgets/dashboard_skeleton.dart';
import 'widgets/kpi_grid.dart';
import 'widgets/module_band.dart';
import 'widgets/module_card.dart';
import 'widgets/my_tasks_card.dart';
import 'widgets/onboarding_card.dart';
import 'widgets/quick_actions_row.dart';
import 'widgets/shortcuts_grid.dart';
import 'widgets/stale_banner.dart';

/// Ana Sayfa -- tek uçtan (GET /dashboard, bkz. dashboard_providers.dart)
/// beslenen "bölüm bölüm özet" (spec §6). Hangi kartın görüneceğine SUNUCU
/// karar verir (anahtarı olmayan bölüm = izin yok, kart çizilmez); istemci
/// yalnızca hızlı işlem butonları ve iskelet tahmini için izne bakar.
/// Mobil hiçbir toplamı yeniden hesaplamaz -- yalnızca biçimler ve oranları
/// çizer. "Bugün" sunucunun İstanbul günüdür; cihaz saati yalnızca "5 dk'dan
/// eski veri" kararında, verinin CİHAZDA alındığı anla farkı olarak
/// kullanılır (bkz. dashboardReceivedAt).
///
/// Sıra: karşılama · Nabız (ya da kurulum rehberi) · Dikkat Gerektirenler ·
/// Hızlı İşlemler · Nakit Akışı / Görevlerim · bantlar · Son Hareketler.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  static const _staleAfter = Duration(minutes: 5);

  final _scroll = ScrollController();
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _onResume);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Uygulamaya dönüldüğünde veri 5 dakikadan eskiyse yenile (spec §6.2).
  /// Yaş, verinin cihazda alındığı andan ölçülür -- sunucu saatiyle cihaz
  /// saati karşılaştırılmaz (saat kayması eşiği kaydırırdı).
  void _onResume() {
    if (!mounted) return;
    final data = ref.read(dashboardProvider).valueOrNull;
    final received = data == null ? null : dashboardReceivedAt[data];
    if (received == null || DateTime.now().difference(received) > _staleAfter) {
      refreshDashboard(ref);
    }
  }

  Future<void> _refresh() => refreshDashboard(ref);

  void _scrollToTopAndRefresh() {
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(homeTabReselectProvider, (_, _) => _scrollToTopAndRefresh());
    final user = ref.watch(authControllerProvider).valueOrNull;
    final async = ref.watch(dashboardProvider);
    final unread = ref.watch(unreadNotificationCountProvider).maybeWhen(data: (c) => c, orElse: () => 0);
    final data = async.valueOrNull;

    final Widget body;
    if (data != null) {
      body = _DashboardContent(data: data, user: user, stale: async.hasError, controller: _scroll, onRefresh: _refresh);
    } else if (async.hasError && !async.isLoading) {
      // Yatay boşluk parça başınadır: hızlı işlem şeridi ekran kenarına
      // kadar uzanır (bkz. QuickActionsRow.inset).
      body = ListView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.symmetric(vertical: kScreenPadding.top),
        children: [
          _inset(DashboardHeader(user: user, data: null)),
          const SizedBox(height: AppSpacing.xl),
          _inset(_DashboardUnavailable(onRetry: _refresh)),
          // Hızlı işlemler özetten bağımsızdır -- özet alınamasa da kalır.
          if (quickActionsFor(user).isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            QuickActionsRow(actions: quickActionsFor(user), inset: kScreenPadding.left),
          ],
          const SizedBox(height: AppSpacing.xl),
          _inset(ShortcutsGrid(user: user)),
        ],
      );
    } else {
      body = ListView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: kScreenPadding,
        children: [
          DashboardHeader(user: user, data: null, loading: true),
          const SizedBox(height: AppSpacing.xl),
          DashboardSkeleton(plan: predictSections(user)),
        ],
      );
    }

    return Scaffold(
      appBar: buildAppBar(
        'Ana Sayfa',
        actions: [
          IconButton(
            icon: Badge(
              label: Text('$unread'),
              isLabelVisible: unread > 0,
              child: const Icon(Icons.notifications_outlined),
            ),
            tooltip: 'Bildirimler',
            onPressed: () => context.push('/diger/bildirimler'),
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _refresh, child: body),
    );
  }
}

/// Sayfa parçasına ekranın yatay kenar boşluğunu verir.
Widget _inset(Widget child) => Padding(
  padding: EdgeInsets.symmetric(horizontal: kScreenPadding.left),
  child: child,
);

class _DashboardContent extends ConsumerWidget {
  const _DashboardContent({
    required this.data,
    required this.user,
    required this.stale,
    required this.controller,
    required this.onRefresh,
  });

  final Dashboard data;
  final User? user;
  final bool stale;
  final ScrollController controller;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hiddenKey = onboardingHiddenKey(user?.organizationId ?? '', data.viewer.userId);
    final hiddenAsync = data.onboarding == null ? null : ref.watch(onboardingHiddenProvider(hiddenKey));
    // "Gizle" tercihi henüz okunmadıysa düzen seçilmez: aksi halde önce
    // kurulum düzeni çizilip tercih gelince normal düzene zıplardı.
    if (hiddenAsync != null && !hiddenAsync.hasValue) {
      return ListView(
        controller: controller,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: kScreenPadding,
        children: [
          DashboardHeader(user: user, data: data),
          const SizedBox(height: AppSpacing.xl),
          DashboardSkeleton(plan: predictSections(user)),
        ],
      );
    }
    final hidden = hiddenAsync?.valueOrNull ?? false;
    final onboarding = onboardingActive(data, hidden: hidden);
    final kpis = pickKpis(data);
    final panel = onboarding ? SecondaryPanel.none : secondaryPanel(data);
    final actions = quickActionsFor(user);
    final bands = layoutBands(data, onboardingActive: onboarding);
    // Son Hareketler: kayıt varsa ya da bölüm o an hesaplanamadıysa (kart
    // başlığıyla hata gövdesi, spec §6.7).
    final hasActivity = (data.sections.activity?.items.isNotEmpty ?? false) || data.sectionErrors.contains('activity');

    void onQuickAction(QuickActionKey action) => runQuickAction(context, action);
    final cardContext = DashCardContext(
      data: data,
      user: user,
      onboardingActive: onboarding,
      hideTaskList: panel == SecondaryPanel.myTasks,
      onQuickAction: onQuickAction,
      onRetry: onRefresh,
    );

    // Parçalar kendi yatay boşluğuyla (_inset) çizilir; yalnızca hızlı
    // işlem şeridi ekran kenarına kadar uzanır ki kısmen görünen kutucuk
    // içerik kenarında kesilmek yerine ekranın altından kaysın.
    final zones = <Widget>[
      if (onboarding)
        _inset(
          OnboardingCard(
            onboarding: data.onboarding!,
            user: user,
            onHide: () => ref.read(onboardingHiddenProvider(hiddenKey).notifier).setHidden(true),
            onQuickAction: onQuickAction,
          ),
        )
      else if (kpis.length >= 2)
        _inset(KpiGrid(data: data, kpis: kpis)),
      if (!onboarding) _inset(AttentionCard(data: data)),
      if (actions.isNotEmpty) QuickActionsRow(actions: actions, inset: kScreenPadding.left),
      if (panel == SecondaryPanel.cash) _inset(CashFlowCard(data: data, onRetry: onRefresh)),
      if (panel == SecondaryPanel.myTasks) _inset(MyTasksCard(data: data)),
      for (final band in bands) _inset(ModuleBand(band: band, cardContext: cardContext)),
      if (hasActivity) _inset(ActivityCard(data: data, onRetry: onRefresh)),
    ];

    return CustomScrollView(
      controller: controller,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.symmetric(vertical: kScreenPadding.top),
          // Sayfa sonlu (~25 parça) -- tek sütun halinde çizilir ki
          // ekran dışı kartlar da ağaçta olsun (erişilebilirlik/testler).
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _inset(DashboardHeader(user: user, data: data)),
                if (stale) ...[
                  const SizedBox(height: AppSpacing.md),
                  _inset(StaleBanner(generatedAt: data.generatedAt, onRetry: onRefresh)),
                ],
                if (data.onboarding != null && hidden) ...[
                  const SizedBox(height: AppSpacing.md),
                  _inset(
                    OnboardingHiddenBar(
                      onShow: () => ref.read(onboardingHiddenProvider(hiddenKey).notifier).setHidden(false),
                    ),
                  ),
                ],
                for (final zone in zones) ...[const SizedBox(height: AppSpacing.xl), zone],
                const SizedBox(height: AppSpacing.lg),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Özet hiç alınamadı (ilk yükleme hatası): karşılama + bu kart + kısayollar.
class _DashboardUnavailable extends StatelessWidget {
  const _DashboardUnavailable({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        children: [
          const Icon(Icons.error_outline, color: AppColors.danger, size: 36),
          const SizedBox(height: AppSpacing.md),
          const Text('Özet yüklenemedi', style: AppTypography.cardTitle, textAlign: TextAlign.center),
          const SizedBox(height: AppSpacing.xs),
          const Text(
            'Bağlantını kontrol edip tekrar dene. Modüllere aşağıdaki kısayollardan ulaşabilirsin.',
            style: AppTypography.metadata,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton(onPressed: onRetry, child: const Text(kCopyRetry)),
        ],
      ),
    );
  }
}
