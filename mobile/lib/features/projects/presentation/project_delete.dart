import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/delete_request.dart';
import '../data/projects_providers.dart';
import '../domain/project.dart';

/// Proje silme (backend migration 0070): projects.delete (Sahip/Yönetici)
/// direkt siler; projeyi düzenleyebilen diğerleri silme talebi gönderir,
/// yetkili onaylar ya da reddeder. Para hareketi olan proje silinmez --
/// sunucu 409 ile neyin engellediğini söyler, proje İptal durumuna alınır.

const kProjectDeletePermission = 'projects.delete';

/// Proje detayının sağ üst "Diğer işlemler" menüsü: "Projeyi Sil" ya da
/// "Silme Talebi Gönder". Gösterilecek seçenek yoksa hiç görünmez.
class ProjectDeleteMenu extends ConsumerWidget {
  const ProjectDeleteMenu({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canDelete = user.canAccess(kProjectDeletePermission);
    final canRequest = !canDelete && user.canAccess('projects.update') && project.deleteRequest == null;
    if (!canDelete && !canRequest) return const SizedBox.shrink();
    return PopupMenuButton<String>(
      key: const ValueKey('project-more-menu'),
      tooltip: 'Diğer işlemler',
      onSelected: (v) {
        if (v == 'sil') _deleteProject(context, ref, project);
        if (v == 'sil-talep') _requestDelete(context, ref, project);
      },
      itemBuilder: (_) => [
        if (canDelete)
          const PopupMenuItem(
            key: ValueKey('project-delete-item'),
            value: 'sil',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline, color: AppColors.danger),
              title: Text('Projeyi Sil', style: TextStyle(color: AppColors.danger)),
            ),
          ),
        if (canRequest)
          const PopupMenuItem(
            key: ValueKey('project-delete-request-item'),
            value: 'sil-talep',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline, color: AppColors.danger),
              title: Text('Silme Talebi Gönder', style: TextStyle(color: AppColors.danger)),
            ),
          ),
      ],
    );
  }
}

/// Bekleyen silme talebi: yetkili onaylar/reddeder, talebi açan geri çeker.
class ProjectDeleteRequestBanner extends ConsumerWidget {
  const ProjectDeleteRequestBanner({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = project.deleteRequest;
    if (request == null) return const SizedBox.shrink();
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canDelete = user.canAccess(kProjectDeletePermission);
    final own = user != null && request.requestedBy == user.id;
    return DeleteRequestNotice(
      key: const ValueKey('project-delete-request-notice'),
      subject: 'bu projenin',
      requestedByName: request.requestedByName,
      createdAt: request.createdAt,
      reason: request.reason,
      onApprove: canDelete ? () => _approve(context, ref, project) : null,
      onReject: canDelete ? () => _reject(context, ref, project) : null,
      onWithdraw: !canDelete && own ? () => _withdraw(context, ref, project) : null,
    );
  }
}

void _invalidateLists(WidgetRef ref) {
  ref.invalidate(projectsListProvider);
  ref.invalidate(projectDeleteRequestsProvider);
}

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// Para hareketi yüzünden silinemeyen projede sunucu mesajı (ne kadar
/// masraf/tahsilat var, ne yapılmalı) pencereyle gösterilir.
Future<void> _showBlocked(BuildContext context, String message) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    key: const ValueKey('project-delete-blocked'),
    title: const Text('Proje silinemiyor'),
    content: Text(message),
    actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Tamam'))],
  ),
);

Future<bool> _confirmDelete(BuildContext context, Project project, {required String confirm}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Projeyi Sil'),
      content: Text(
        '${project.projectNo} (${project.name}) silinsin mi? Görevleri, notları, dosya ve fotoğrafları, ödeme planı '
        've ek işleriyle birlikte kalıcı olarak silinir. Bu işlem geri alınamaz.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
        TextButton(
          key: const ValueKey('project-delete-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return ok == true;
}

Future<void> _deleteProject(BuildContext context, WidgetRef ref, Project project) async {
  if (!await _confirmDelete(context, project, confirm: 'Sil')) return;
  try {
    await ref.read(projectsRepositoryProvider).deleteProject(project.id);
    _invalidateLists(ref);
    if (!context.mounted) return;
    _snack(context, '${project.projectNo} silindi');
    context.go('/projeler');
  } on ApiException catch (e) {
    if (!context.mounted) return;
    if (e.kind == ApiErrorKind.conflict) {
      await _showBlocked(context, e.message);
    } else {
      _snack(context, e.message);
    }
  }
}

Future<void> _requestDelete(BuildContext context, WidgetRef ref, Project project) async {
  final reason = await showNoteDialog(
    context,
    title: 'Silme Talebi Gönder',
    message:
        '${project.projectNo} (${project.name}) için silme talebi yöneticiye gider. Onaylanırsa proje '
        'kalıcı olarak silinir.',
    label: 'Neden silinsin? (isteğe bağlı)',
    confirm: 'Talep Gönder',
    keyName: 'project-delete-request-reason',
  );
  if (reason == null || !context.mounted) return;
  try {
    await ref.read(projectsRepositoryProvider).requestProjectDelete(project.id, reason: reason);
    ref.invalidate(projectDetailProvider(project.id));
    if (!context.mounted) return;
    _snack(context, 'Silme talebi gönderildi. Yönetici onaylayınca proje silinir.');
  } on ApiException catch (e) {
    if (!context.mounted) return;
    if (e.kind == ApiErrorKind.conflict && e.message.contains('silinemez')) {
      await _showBlocked(context, e.message);
    } else {
      ref.invalidate(projectDetailProvider(project.id));
      _snack(context, e.message);
    }
  }
}

Future<void> _approve(BuildContext context, WidgetRef ref, Project project) async {
  if (!await _confirmDelete(context, project, confirm: 'Onayla ve Sil')) return;
  try {
    await ref.read(projectsRepositoryProvider).approveProjectDeleteRequest(project.id);
    _invalidateLists(ref);
    if (!context.mounted) return;
    _snack(context, '${project.projectNo} silindi');
    context.go('/projeler');
  } on ApiException catch (e) {
    if (!context.mounted) return;
    if (e.kind == ApiErrorKind.conflict && e.message.contains('silinemez')) {
      await _showBlocked(context, e.message);
    } else {
      ref.invalidate(projectDetailProvider(project.id));
      _snack(context, e.message);
    }
  }
}

Future<void> _reject(BuildContext context, WidgetRef ref, Project project) async {
  final note = await showNoteDialog(
    context,
    title: 'Silme Talebini Reddet',
    message: '${project.projectNo} silinmeyecek; talep eden kişiye bildirim gider.',
    label: 'Gerekçe (isteğe bağlı)',
    confirm: 'Reddet',
    keyName: 'project-delete-reject-note',
  );
  if (note == null || !context.mounted) return;
  try {
    await ref.read(projectsRepositoryProvider).rejectProjectDeleteRequest(project.id, note: note);
    ref.invalidate(projectDetailProvider(project.id));
    ref.invalidate(projectDeleteRequestsProvider);
    if (!context.mounted) return;
    _snack(context, 'Silme talebi reddedildi');
  } on ApiException catch (e) {
    ref.invalidate(projectDetailProvider(project.id));
    if (!context.mounted) return;
    _snack(context, e.message);
  }
}

Future<void> _withdraw(BuildContext context, WidgetRef ref, Project project) async {
  try {
    await ref.read(projectsRepositoryProvider).withdrawProjectDeleteRequest(project.id);
    ref.invalidate(projectDetailProvider(project.id));
    if (!context.mounted) return;
    _snack(context, 'Silme talebi geri çekildi');
  } on ApiException catch (e) {
    ref.invalidate(projectDetailProvider(project.id));
    if (!context.mounted) return;
    _snack(context, e.message);
  }
}
