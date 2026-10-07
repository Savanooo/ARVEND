import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_filter_bar.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/projects_providers.dart';
import 'project_list_card.dart';

class ProjectsScreen extends ConsumerStatefulWidget {
  const ProjectsScreen({super.key, this.initialStatus});

  /// `/projeler?status=completed` -- ana sayfadaki "Tamamlananlar"
  /// bağlantısı gibi derin bağlantılar için başlangıç süzgeci. Tanınmayan
  /// değer yok sayılır ("Tümü").
  final String? initialStatus;

  @override
  ConsumerState<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends ConsumerState<ProjectsScreen> {
  late String? _status = _known(widget.initialStatus);
  final _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';

  static String? _known(String? status) => StatusRegistry.project.containsKey(status) ? status : null;

  ProjectsListQuery get _listQuery => (status: _status, q: _query);

  @override
  void didUpdateWidget(covariant ProjectsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sekme dalı açık kalır: aynı ekrana yeni bir ?status= ile gelinirse
    // süzgeç ona geçer.
    final next = _known(widget.initialStatus);
    if (widget.initialStatus != oldWidget.initialStatus && next != null) _status = next;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Arama sunucuda yapılır; her tuşta değil, yazma durunca istek atılır.
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _applySearch(value));
  }

  void _applySearch(String value) {
    _debounce?.cancel();
    final q = value.trim();
    if (q != _query && mounted) setState(() => _query = q);
  }

  Future<void> _refresh() async {
    ref.invalidate(projectsListProvider(_listQuery));
    try {
      await ref.read(projectsListProvider(_listQuery).future);
    } catch (_) {
      // Hata ekranda gösterilir.
    }
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < 400) {
      ref.read(projectsListProvider(_listQuery).notifier).loadMore(auto: true);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final projectsAsync = ref.watch(projectsListProvider(_listQuery));

    return Scaffold(
      appBar: buildAppBar('Projeler'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              0,
            ),
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _searchController,
              builder: (context, value, _) => TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Proje adı, no veya müşteri ara',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  suffixIcon: value.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Aramayı temizle',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _searchController.clear();
                            _applySearch('');
                          },
                        ),
                ),
                onChanged: _onSearchChanged,
                onSubmitted: _applySearch,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.xs,
            ),
            child: AppFilterBar(
              chips: [
                AppFilterChipData(
                  label: 'Tümü',
                  selected: _status == null,
                  onTap: () => setState(() => _status = null),
                ),
                for (final entry in StatusRegistry.project.entries)
                  AppFilterChipData(
                    label: entry.value.$1,
                    selected: _status == entry.key,
                    onTap: () => setState(() => _status = entry.key),
                  ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: AsyncStateView(
                value: projectsAsync,
                onRetry: _refresh,
                isEmpty: (page) => page.projects.isEmpty,
                emptyBuilder: (_) => EmptyStateView(
                  message: _query.isEmpty ? 'Bu filtreye uyan proje yok.' : '“$_query” için proje bulunamadı.',
                  icon: Icons.business_outlined,
                ),
                data: (context, page) => NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: kScreenPadding,
                    children: [
                      for (final p in page.projects)
                        ProjectListCard(
                          project: p,
                          onTap: () => context.push('/projeler/${p.id}'),
                        ),
                      _LoadMoreFooter(
                        page: page,
                        onLoadMore: () => ref.read(projectsListProvider(_listQuery).notifier).loadMore(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Liste sonu: yükleniyor / hata + tekrar dene / "daha fazla" düğmesi.
class _LoadMoreFooter extends StatelessWidget {
  const _LoadMoreFooter({required this.page, required this.onLoadMore});
  final ProjectsPage page;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (page.loadingMore) {
      return const Padding(padding: EdgeInsets.all(AppSpacing.lg), child: LoadingState());
    }
    final error = page.loadMoreError;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Column(
          children: [
            Text(
              error is ApiException ? error.message : 'Beklenmeyen bir hata oluştu.',
              style: AppTypography.error,
              textAlign: TextAlign.center,
            ),
            TextButton(onPressed: onLoadMore, child: const Text('Tekrar Dene')),
          ],
        ),
      );
    }
    if (page.hasMore) {
      return Center(
        child: TextButton(
          onPressed: onLoadMore,
          child: Text('Daha fazla göster (${page.projects.length} / ${page.total})'),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
