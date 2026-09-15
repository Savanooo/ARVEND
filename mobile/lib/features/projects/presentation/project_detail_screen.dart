import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/projects_providers.dart';
import '../domain/project.dart';
import 'expense_form_sheet.dart';

/// RBAC/Project Membership sprint'i: sekmeler kullanıcının izin kümesine
/// göre GİZLENİR (spec: "no finance section shown without finance
/// permission") -- bu YALNIZCA UX'tir, gerçek sınır zaten backend'de (bu
/// sekme gösterilse bile ilgili uç 403 döner). owner/admin/legacy_user
/// TÜM izinlere sahip olduğu için onlar için hiçbir sekme gizlenmez.
class _TabDef {
  const _TabDef(this.label, this.permission, this.builder);
  final String label;
  final String? permission; // null = her zaman görünür.
  final Widget Function(String projectId, Project project) builder;
}

final _tabDefs = <_TabDef>[
  _TabDef('Genel', null, (id, p) => _GeneralTab(project: p)),
  _TabDef('Finans', 'projects.finance.read', (id, p) => _FinanceTab(projectId: id, project: p)),
  _TabDef('Operasyon', 'projects.tasks.read', (id, p) => _OperationsTab(projectId: id)),
  _TabDef('Dosyalar', 'projects.operations.read', (id, p) => _FilesTab(projectId: id)),
  _TabDef('Aktivite', null, (id, p) => _ActivityTab(projectId: id)),
];

class ProjectDetailScreen extends ConsumerWidget {
  const ProjectDetailScreen({super.key, required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(projectDetailProvider(projectId));
    final user = ref.watch(authControllerProvider).valueOrNull;
    // super_admin bu ekrana zaten hiç gelmez (mobil kapsamı yok); permissions
    // boşsa (nadir, henüz yüklenmemiş) TÜM sekmeler gösterilir -- geçici bir
    // "her şey gizli" yanılsaması yaratmamak için (backend zaten 403 üretir).
    final visibleTabs = user == null || user.permissions.isEmpty
        ? _tabDefs
        : _tabDefs.where((t) => t.permission == null || user.hasPermission(t.permission!)).toList();

    return DefaultTabController(
      length: visibleTabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: projectAsync.maybeWhen(
            data: (p) => Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            orElse: () => const Text('Proje'),
          ),
          bottom: TabBar(
            isScrollable: true,
            tabs: [for (final t in visibleTabs) Tab(text: t.label)],
          ),
        ),
        body: AsyncStateView(
          value: projectAsync,
          onRetry: () async => ref.invalidate(projectDetailProvider(projectId)),
          data: (context, project) => TabBarView(
            children: [for (final t in visibleTabs) t.builder(projectId, project)],
          ),
        ),
      ),
    );
  }
}

class _GeneralTab extends StatelessWidget {
  const _GeneralTab({required this.project});
  final Project project;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(project.projectNo, style: const TextStyle(fontWeight: FontWeight.w700)),
                    StatusRegistry.build(project.status, StatusRegistry.project),
                  ],
                ),
                const SizedBox(height: 12),
                _InfoRow(label: 'Proje Türü', value: project.projectType.isEmpty ? '-' : project.projectType),
                _InfoRow(
                    label: 'Sözleşme Tutarı',
                    value: Formatters.money(project.contractAmount, currency: project.currency)),
                _InfoRow(label: 'Başlangıç', value: Formatters.date(project.startDate)),
                _InfoRow(label: 'Bitiş', value: Formatters.date(project.endDate)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Müşteri Bilgileri', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                _InfoRow(label: 'Ad', value: project.customerName),
                _InfoRow(label: 'Telefon', value: project.customerPhone.isEmpty ? '-' : project.customerPhone),
                _InfoRow(label: 'E-posta', value: project.customerEmail.isEmpty ? '-' : project.customerEmail),
              ],
            ),
          ),
        ),
        if (project.description.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Açıklama', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(project.description),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _FinanceTab extends ConsumerWidget {
  const _FinanceTab({required this.projectId, required this.project});
  final String projectId;
  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(projectFinancialSummaryProvider(projectId));
    final expensesAsync = ref.watch(projectExpensesProvider(projectId));

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(projectFinancialSummaryProvider(projectId));
        ref.invalidate(projectExpensesProvider(projectId));
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AsyncStateView(
            value: summaryAsync,
            onRetry: () async => ref.invalidate(projectFinancialSummaryProvider(projectId)),
            data: (context, s) => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _InfoRow(label: 'Güncel Sözleşme Bedeli', value: Formatters.money(s.currentContractValue, currency: s.currency), emphasize: true),
                    _InfoRow(label: 'Tahsil Edilen', value: Formatters.money(s.collectedAmount, currency: s.currency)),
                    _InfoRow(label: 'Kalan Alacak', value: Formatters.money(s.remainingReceivable, currency: s.currency)),
                    const Divider(height: 20),
                    _InfoRow(label: 'Gerçekleşen Maliyet', value: Formatters.money(s.realizedCost, currency: s.currency)),
                    _InfoRow(label: 'Taahhüt Edilen Maliyet', value: Formatters.money(s.committedCost, currency: s.currency)),
                    _InfoRow(label: 'Gerçekleşen Kâr', value: Formatters.money(s.realizedGrossProfit, currency: s.currency)),
                    _InfoRow(label: 'Tahmini Kâr', value: Formatters.money(s.estimatedGrossProfit, currency: s.currency)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Masraflar', style: TextStyle(fontWeight: FontWeight.w700)),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Masraf Ekle'),
                onPressed: () async {
                  final created = await showExpenseFormSheet(context, projectId, currency: project.currency);
                  if (created != null) {
                    ref.invalidate(projectExpensesProvider(projectId));
                    ref.invalidate(projectFinancialSummaryProvider(projectId));
                  }
                },
              ),
            ],
          ),
          AsyncStateView(
            value: expensesAsync,
            onRetry: () async => ref.invalidate(projectExpensesProvider(projectId)),
            isEmpty: (list) => list.isEmpty,
            emptyBuilder: (_) => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: EmptyStateView(message: 'Henüz masraf kaydı yok.'),
            ),
            data: (context, expenses) => Column(
              children: expenses
                  .map((e) => Card(
                        margin: const EdgeInsets.only(top: 8),
                        child: ListTile(
                          title: Text(expenseCategories[e.category] ?? e.category),
                          subtitle: Text(
                            [e.description, if (e.supplierName.isNotEmpty) e.supplierName].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            Formatters.money(e.amount, currency: e.currency.isEmpty ? project.currency : e.currency),
                            style: TextStyle(
                              decoration: e.isVoided ? TextDecoration.lineThrough : null,
                              fontWeight: FontWeight.w600,
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

class _OperationsTab extends ConsumerWidget {
  const _OperationsTab({required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasksAsync = ref.watch(projectTasksProvider(projectId));

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(projectTasksProvider(projectId)),
      child: AsyncStateView(
        value: tasksAsync,
        onRetry: () async => ref.invalidate(projectTasksProvider(projectId)),
        isEmpty: (list) => list.isEmpty,
        emptyBuilder: (_) => const EmptyStateView(message: 'Görev yok.'),
        data: (context, tasks) => ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: tasks.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final t = tasks[i];
            return Card(
              child: ListTile(
                leading: Checkbox(
                  value: t.status == 'completed',
                  onChanged: t.status == 'completed'
                      ? null
                      : (_) async {
                          await ref.read(projectsRepositoryProvider).completeTask(projectId, t.id);
                          ref.invalidate(projectTasksProvider(projectId));
                        },
                ),
                title: Text(
                  t.title,
                  style: t.status == 'completed' ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
                ),
                subtitle: Text([
                  if (t.assignedName.isNotEmpty) t.assignedName,
                  if (t.dueDate != null) Formatters.date(t.dueDate),
                ].join(' · ')),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    StatusRegistry.build(t.status, StatusRegistry.task),
                    if (t.isOverdue) const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _FilesTab extends ConsumerStatefulWidget {
  const _FilesTab({required this.projectId});
  final String projectId;

  @override
  ConsumerState<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends ConsumerState<_FilesTab> {
  String get projectId => widget.projectId;
  bool _uploading = false;

  Future<void> _pickAndUploadPhoto(ImageSource source) async {
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 85);
    if (picked == null) return;
    final file = File(picked.path);
    final size = await file.length();
    if (size > AppConfig.maxUploadBytes) {
      _showError('Fotoğraf 25 MiB sınırını aşıyor (${(size / 1024 / 1024).toStringAsFixed(1)} MB).');
      return;
    }
    setState(() => _uploading = true);
    try {
      await ref.read(projectsRepositoryProvider).uploadPhoto(
            projectId,
            filePath: picked.path,
            fileName: picked.name,
          );
      ref.invalidate(projectPhotosProvider(projectId));
    } on ApiException catch (e) {
      _showError(e.message);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _pickAndUploadFile() async {
    final result = await FilePicker.platform.pickFiles(withData: false);
    final picked = result?.files.single;
    if (picked == null || picked.path == null) return;
    if (picked.size > AppConfig.maxUploadBytes) {
      _showError('Dosya 25 MiB sınırını aşıyor (${(picked.size / 1024 / 1024).toStringAsFixed(1)} MB).');
      return;
    }
    setState(() => _uploading = true);
    try {
      await ref.read(projectsRepositoryProvider).uploadFile(
            projectId,
            filePath: picked.path!,
            fileName: picked.name,
          );
      ref.invalidate(projectFilesProvider(projectId));
    } on ApiException catch (e) {
      _showError(e.message);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final photosAsync = ref.watch(projectPhotosProvider(projectId));
    final filesAsync = ref.watch(projectFilesProvider(projectId));

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(projectPhotosProvider(projectId));
        ref.invalidate(projectFilesProvider(projectId));
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_uploading) const LinearProgressIndicator(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Şantiye Fotoğrafları', style: TextStyle(fontWeight: FontWeight.w700)),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.photo_camera_outlined),
                    tooltip: 'Kameradan çek',
                    onPressed: _uploading ? null : () => _pickAndUploadPhoto(ImageSource.camera),
                  ),
                  IconButton(
                    icon: const Icon(Icons.photo_library_outlined),
                    tooltip: 'Galeriden seç',
                    onPressed: _uploading ? null : () => _pickAndUploadPhoto(ImageSource.gallery),
                  ),
                ],
              ),
            ],
          ),
          AsyncStateView(
            value: photosAsync,
            isEmpty: (l) => l.isEmpty,
            emptyBuilder: (_) => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Fotoğraf yok.', style: TextStyle(color: Colors.grey)),
            ),
            data: (context, photos) => SizedBox(
              height: 90,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: photos.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    ref.read(projectsRepositoryProvider).photoContentUrl(projectId, photos[i].id),
                    width: 90,
                    height: 90,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 90,
                      height: 90,
                      color: Colors.grey.shade200,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Dosyalar', style: TextStyle(fontWeight: FontWeight.w700)),
              IconButton(
                icon: const Icon(Icons.upload_file_outlined),
                tooltip: 'Dosya yükle',
                onPressed: _uploading ? null : _pickAndUploadFile,
              ),
            ],
          ),
          AsyncStateView(
            value: filesAsync,
            isEmpty: (l) => l.isEmpty,
            emptyBuilder: (_) => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Dosya yok.', style: TextStyle(color: Colors.grey)),
            ),
            data: (context, files) => Column(
              children: files
                  .map((f) => Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          leading: const Icon(Icons.insert_drive_file_outlined),
                          title: Text(f.originalName, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${(f.sizeBytes / 1024).toStringAsFixed(0)} KB'),
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

class _ActivityTab extends ConsumerWidget {
  const _ActivityTab({required this.projectId});
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder(
      future: ref.read(projectsRepositoryProvider).events(projectId),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final events = snapshot.data ?? [];
        if (events.isEmpty) return const EmptyStateView(message: 'Aktivite kaydı yok.');
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: events.length,
          separatorBuilder: (_, _) => const Divider(),
          itemBuilder: (context, i) {
            final e = events[i];
            return ListTile(
              dense: true,
              title: Text(e['event_type'] as String? ?? ''),
              subtitle: Text(Formatters.dateTime(e['created_at'] as String?)),
            );
          },
        );
      },
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.emphasize = false});
  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13)),
          Text(
            value,
            style: TextStyle(fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600, fontSize: emphasize ? 16 : 13),
          ),
        ],
      ),
    );
  }
}
