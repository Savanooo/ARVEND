import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/theme/app_spacing.dart';
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
  String _query = '';

  static String? _known(String? status) => StatusRegistry.project.containsKey(status) ? status : null;

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
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final projectsAsync = ref.watch(projectsListProvider(_status));

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
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Proje adı veya müşteri ara',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
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
              onRefresh: () async =>
                  ref.invalidate(projectsListProvider(_status)),
              child: AsyncStateView(
                value: projectsAsync,
                onRetry: () async =>
                    ref.invalidate(projectsListProvider(_status)),
                isEmpty: (r) => r.projects.isEmpty,
                data: (context, r) {
                  final filtered = _query.isEmpty
                      ? r.projects
                      : r.projects
                            .where(
                              (p) =>
                                  p.name.toLowerCase().contains(_query) ||
                                  p.customerName.toLowerCase().contains(
                                    _query,
                                  ) ||
                                  p.projectNo.toLowerCase().contains(_query),
                            )
                            .toList();
                  if (filtered.isEmpty) {
                    return const EmptyStateView(
                      message: 'Bu filtreye uyan proje yok.',
                      icon: Icons.business_outlined,
                    );
                  }
                  return ListView(
                    padding: kScreenPadding,
                    children: [
                      for (final p in filtered)
                        ProjectListCard(
                          project: p,
                          onTap: () => context.push('/projeler/${p.id}'),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
