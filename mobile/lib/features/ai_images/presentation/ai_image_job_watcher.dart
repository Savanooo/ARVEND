import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/push/push_watcher.dart' show rootScaffoldMessengerKey;
import '../../projects/data/projects_providers.dart';
import '../../projects/domain/project.dart';
import '../../projects/presentation/project_photo_gallery.dart';
import '../data/ai_images_providers.dart';
import '../domain/ai_image.dart';

const kAiReadyText = 'Görsel hazır';
const kAiShowAction = 'Göster';

/// Uygulamanın kökünde durur: izlenen bir yapay zekâ işi bitince, kullanıcı
/// hangi ekranda olursa olsun alt bant gösterir -- hazırsa "Görsel hazır ·
/// Göster" (galeride o görselde açar), başarısızsa sunucunun Türkçe nedeni.
/// Sayfa kapatılmış olabileceği için bant sayfaya değil köke bağlıdır.
class AiImageJobWatcher extends ConsumerStatefulWidget {
  const AiImageJobWatcher({super.key, required this.navigatorKey, required this.child});

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  ConsumerState<AiImageJobWatcher> createState() => _AiImageJobWatcherState();
}

class _AiImageJobWatcherState extends ConsumerState<AiImageJobWatcher> {
  void _announce(AiImageJob job) {
    final messenger = rootScaffoldMessengerKey.currentState;
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    if (job.isDone) {
      messenger.showSnackBar(SnackBar(
        content: const Text(kAiReadyText),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(label: kAiShowAction, onPressed: () => _open(job)),
      ));
    } else {
      messenger.showSnackBar(SnackBar(
        content: Text(job.error.trim().isEmpty ? 'Görsel hazırlanamadı; tekrar deneyin.' : job.error),
        duration: const Duration(seconds: 8),
      ));
    }
  }

  Future<void> _open(AiImageJob job) async {
    final resultId = job.resultPhotoId;
    if (resultId == null) return;
    try {
      final photos = sortPhotosByStage(await ref.read(projectsRepositoryProvider).photos(job.projectId));
      final index = photos.indexWhere((p) => p.id == resultId);
      final navContext = widget.navigatorKey.currentContext;
      if (index < 0 || navContext == null || !navContext.mounted) return;
      final user = ref.read(authControllerProvider).valueOrNull;
      await showProjectPhotoGallery(
        navContext,
        projectId: job.projectId,
        photos: photos,
        initialIndex: index,
        canDelete: user.can('projects.operations.manage'),
        canUseAi: true,
      );
    } on ApiException catch (e) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Map<String, AiImageJob>>(aiImageJobsProvider, (previous, next) {
      for (final job in next.values) {
        final before = previous?[job.id];
        if (before != null && before.isActive && !job.isActive) _announce(job);
      }
    });
    return widget.child;
  }
}
