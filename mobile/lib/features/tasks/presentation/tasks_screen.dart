import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/app_shell.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_filter_bar.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../../dashboard/presentation/widgets/project_picker_sheet.dart';
import '../../projects/domain/project.dart';
import '../data/tasks_providers.dart';
import '../domain/task_filters.dart';
import 'task_complete_checkbox.dart';

/// Global görevler. İki görünüm:
/// - "Benim": GET /tasks/mine -- bana atananlar.
/// - "Ekip": GET /tasks/team -- erişilebilir projelerdeki tüm görevler;
///   yönetici buradan atar ("Görev Ata") ve takip eder (sahada 2026-10).
/// Durum filtresi backend'e GİDER (`status` query param); gecikme/öncelik/
/// proje/kişi/arama filtreleri çekilmiş TEK listenin üzerinde istemci
/// tarafında uygulanır.
class TasksScreen extends ConsumerStatefulWidget {
  const TasksScreen({super.key});

  @override
  ConsumerState<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends ConsumerState<TasksScreen> {
  String _statusMode = 'open';
  bool _overdueOnly = false;
  String? _priorityFilter;
  String? _projectFilter;
  String? _assigneeFilter;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _assign() async {
    final project = await showProjectPickerSheet(context);
    if (project == null || !mounted) return;
    await context.push('/projeler/${project.id}/gorevler/yeni?donus=liste');
    if (!mounted) return;
    invalidateTaskLists(ref);
  }

  void _setScope(String scope) {
    ref.read(tasksScopeProvider.notifier).state = scope;
    setState(() {
      _projectFilter = null;
      _assigneeFilter = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    // Varsayılan görünüm izne bağlı: kullanıcı yüklenmeden karar verilirse
    // önce yanlış liste çekilir, sonra doğrusu.
    if (auth.isLoading && !auth.hasValue) {
      return Scaffold(appBar: buildAppBar('Görevler'), body: const LoadingState());
    }
    final user = auth.valueOrNull;
    final canAssign =
        user == null || user.permissions.isEmpty || user.hasPermission('projects.tasks.create');
    // Görev atayabilen (yönetici) Ekip ile, diğerleri kendi görevleriyle açar.
    final scope = ref.watch(tasksScopeProvider) ?? (canAssign ? 'team' : 'mine');
    final isTeam = scope == 'team';
    final provider = isTeam ? teamTasksProvider(_statusMode) : myTasksProvider(_statusMode);
    final tasksAsync = ref.watch(provider);

    return Scaffold(
      appBar: buildAppBar('Görevler'),
      floatingActionButton: canAssign
          ? FloatingActionButton.extended(
              key: const Key('gorev-ata'),
              onPressed: _assign,
              icon: const Icon(Icons.add_task),
              label: const Text('Görev Ata'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(provider),
        child: ListView(
          padding: kScreenPadding.copyWith(bottom: canAssign ? 96 : null),
          children: [
            SegmentedButton<String>(
              key: const Key('gorev-gorunum'),
              segments: const [
                ButtonSegment(value: 'mine', icon: Icon(Icons.person_outline), label: Text('Benim')),
                ButtonSegment(value: 'team', icon: Icon(Icons.groups_outlined), label: Text('Ekip')),
              ],
              selected: {scope},
              onSelectionChanged: (s) => _setScope(s.first),
            ),
            const SizedBox(height: AppSpacing.sm),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'open', label: Text('Açık')),
                ButtonSegment(value: 'all', label: Text('Tümü')),
                ButtonSegment(
                  value: ProjectTask.statusCompleted,
                  label: Text('Tamamlanan'),
                ),
              ],
              selected: {_statusMode},
              onSelectionChanged: (s) => setState(() => _statusMode = s.first),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: isTeam ? 'Başlık, proje veya kişi ara' : 'Başlık veya proje ara',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.sm),
            // Tek satır, yatay kayar (eskiden iki satıra sarıyordu).
            AppFilterBar(
              chips: [
                AppFilterChipData(
                  label: 'Yalnızca gecikmiş',
                  selected: _overdueOnly,
                  onTap: () => setState(() => _overdueOnly = !_overdueOnly),
                ),
                for (final p in const [
                  (ProjectTask.priorityUrgent, 'Acil'),
                  (ProjectTask.priorityHigh, 'Yüksek'),
                  (ProjectTask.priorityNormal, 'Normal'),
                  (ProjectTask.priorityLow, 'Düşük'),
                ])
                  AppFilterChipData(
                    label: p.$2,
                    selected: _priorityFilter == p.$1,
                    onTap: () => setState(
                      () => _priorityFilter = _priorityFilter == p.$1
                          ? null
                          : p.$1,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            AsyncStateView<TaskListPage>(
              value: tasksAsync,
              onRetry: () async => ref.invalidate(provider),
              data: (context, page) {
                final allItems = page.items;
                if (allItems.isEmpty) {
                  if (!isTeam && page.linkedEmployee == false) {
                    return _NotLinkedNotice(
                      onShowTeam: canAssign ? () => _setScope('team') : null,
                    );
                  }
                  return EmptyStateView(
                    message: isTeam
                        ? (canAssign
                            ? 'Görev yok. "Görev Ata" ile projeye görev verebilirsin.'
                            : 'Görev yok.')
                        : 'Sana atanmış görev yok.',
                    icon: Icons.checklist_outlined,
                  );
                }

                final projects = <String, String>{};
                final people = <String, String>{};
                var hasUnassigned = false;
                for (final (task, projectId, projectName) in allItems) {
                  projects[projectId] = projectName;
                  final id = task.assignedEmployeeId ?? '';
                  if (id.isEmpty) {
                    hasUnassigned = true;
                  } else {
                    people[id] = task.assignedName.isEmpty ? 'İsimsiz' : task.assignedName;
                  }
                }
                final items = allItems
                    .where(
                      (item) => myTaskMatchesFilters(
                        item.$1,
                        item.$2,
                        item.$3,
                        overdueOnly: _overdueOnly,
                        priority: _priorityFilter,
                        projectFilter: _projectFilter,
                        assigneeFilter: isTeam ? _assigneeFilter : null,
                        searchQuery: _searchController.text,
                      ),
                    )
                    .toList();
                final showPeople = isTeam && (people.length + (hasUnassigned ? 1 : 0)) > 1;

                final projectField = projects.length > 1
                    ? DropdownButtonFormField<String>(
                        key: ValueKey('proje-$scope'),
                        initialValue: _projectFilter ?? '',
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Proje',
                          isDense: true,
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child: Text('Tüm projeler'),
                          ),
                          ...projects.entries.map(
                            (e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value, overflow: TextOverflow.ellipsis),
                            ),
                          ),
                        ],
                        onChanged: (v) => setState(
                          () => _projectFilter = (v == null || v.isEmpty)
                              ? null
                              : v,
                        ),
                      )
                    : null;
                final peopleField = showPeople
                    ? DropdownButtonFormField<String>(
                        key: const Key('gorev-kisi'),
                        initialValue: _assigneeFilter ?? '',
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Kişi',
                          isDense: true,
                        ),
                        items: [
                          const DropdownMenuItem(value: '', child: Text('Herkes')),
                          ...(people.entries.toList()
                                ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase())))
                              .map(
                            (e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value, overflow: TextOverflow.ellipsis),
                            ),
                          ),
                          if (hasUnassigned)
                            const DropdownMenuItem(value: kUnassignedFilter, child: Text('Atanmamış')),
                        ],
                        onChanged: (v) => setState(
                          () => _assigneeFilter = (v == null || v.isEmpty) ? null : v,
                        ),
                      )
                    : null;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (isTeam && page.truncated)
                      _TruncatedNotice(shown: allItems.length, total: page.total),
                    // Proje ve kişi yan yana: telefonda filtreler listeyi
                    // ekranın altına itmesin (sahada görevlerin yalnızca
                    // biri görünüyordu).
                    if (projectField != null || peopleField != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: Row(
                          children: [
                            if (projectField != null) Expanded(child: projectField),
                            if (projectField != null && peopleField != null)
                              const SizedBox(width: AppSpacing.sm),
                            if (peopleField != null) Expanded(child: peopleField),
                          ],
                        ),
                      ),
                    if (items.isEmpty)
                      const EmptyStateView(
                        message: 'Bu filtreye uyan görev yok.',
                        icon: Icons.checklist_outlined,
                      )
                    else
                      for (final item in items)
                        _TaskRow(item: item, showAssignee: isTeam),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// "Ekip" listesi sunucuda üst sınırda kesildi: kalan görevler yok değil,
/// yalnızca gösterilmiyor. Proje/kişi/arama filtreleri de yalnızca
/// gösterilenler üzerinde çalışır -- kullanıcı bunu bilmeli.
class _TruncatedNotice extends StatelessWidget {
  const _TruncatedNotice({required this.shown, this.total});
  final int shown;
  final int? total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('gorev-liste-kesildi'),
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 16, color: AppColors.warning),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              'İlk $shown görev gösteriliyor${total != null ? ' (toplam $total)' : ''}. '
              'Filtreler yalnızca bunlara uygulanır; durum seçimiyle (Açık/Tamamlanan) listeyi daralt.',
              style: AppTypography.helper,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Benim" boş ve hesap bir personel kaydına bağlı değil: görev personele
/// atanır, kişiye değil -- bu hesaba hiçbir zaman görev düşmez. Sessiz bir
/// "Görev yok" bunu saklardı.
class _NotLinkedNotice extends StatelessWidget {
  const _NotLinkedNotice({this.onShowTeam});
  final VoidCallback? onShowTeam;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      key: const Key('gorev-bagli-degil'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.link_off, size: 20, color: AppColors.warning),
              SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Hesabın bir personel kaydına bağlı değil',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Görevler personele atanır; bu yüzden sana görev düşmüyor. '
            'Personel ekranında kişiye giriş hesabı açılınca görevleri burada görünür.',
            style: AppTypography.body.copyWith(color: AppColors.textMuted),
          ),
          if (onShowTeam != null) ...[
            const SizedBox(height: AppSpacing.sm),
            TextButton.icon(
              onPressed: onShowTeam,
              icon: const Icon(Icons.groups_outlined),
              label: const Text('Ekibin görevlerini göster'),
            ),
          ],
        ],
      ),
    );
  }
}

class _TaskRow extends ConsumerWidget {
  const _TaskRow({required this.item, required this.showAssignee});
  final ProjectTaskWithProject item;

  /// "Ekip" görünümü: kime atandığı yazılır; başkasının görevi listeden
  /// tek dokunuşla tamamlanmasın diye onay kutusu yerine durum ikonu.
  final bool showAssignee;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (task, projectId, projectName) = item;
    final done = task.status == ProjectTask.statusCompleted;
    return AppListCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      onTap: () => context.push('/projeler/$projectId/gorevler/${task.id}'),
      leading: showAssignee
          ? Icon(
              done
                  ? Icons.check_circle
                  : task.status == ProjectTask.statusInProgress
                      ? Icons.timelapse
                      : Icons.radio_button_unchecked,
              color: done ? AppColors.success : AppColors.textMuted,
            )
          : TaskCompleteCheckbox(projectId: projectId, task: task),
      title: task.title,
      subtitle: showAssignee
          ? '$projectName · ${task.assignedName.isNotEmpty ? task.assignedName : 'Atanmamış'}'
          : projectName,
      // Proje tamamlandı/iptal: görev açık görünse de üzerinde çalışılmıyor
      // olabilir; sunucu onu gecikmiş de saymaz.
      footer: task.projectClosed
          ? Align(
              alignment: Alignment.centerLeft,
              child: StatusBadge(key: Key('proje-kapali-${task.id}'), label: 'Proje kapalı', tone: StatusTone.muted),
            )
          : null,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          StatusRegistry.build(task.priority, StatusRegistry.taskPriority),
          if (task.dueDate != null) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (task.isOverdue) ...[
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 12,
                    color: AppColors.danger,
                  ),
                  const SizedBox(width: 2),
                ],
                Text(
                  Formatters.date(task.dueDate),
                  style: AppTypography.helper.copyWith(
                    color: task.isOverdue
                        ? AppColors.danger
                        : AppColors.textMuted,
                    fontWeight: task.isOverdue
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
