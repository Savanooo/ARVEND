import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/errors/device_errors.dart';
import '../../../core/files/file_share.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_sheet.dart';
import '../../dashboard/domain/dashboard.dart' show ProjectOption;
import '../../dashboard/presentation/widgets/project_picker_sheet.dart';
import '../../projects/data/projects_providers.dart';
import '../../projects/presentation/form_project_banner.dart' show formProjectLabel;
import '../../projects/presentation/project_photo_gallery.dart' show GalleryZoomPage;
import '../data/ai_studio_providers.dart';
import '../domain/ai_image.dart';
import '../domain/ai_studio.dart';
import 'ai_badge.dart';
import 'ai_studio_sheets.dart' show showAiStudioRefineSheet;

/// Stüdyo görsellerini tam ekran açar (kök navigator: alt menünün üstü de
/// kaplanır). Hareketler proje galerisiyle aynı (GalleryZoomPage): yatay
/// kaydırma, iki parmak/çift dokunuş yakınlaştırma, aşağı çekip kapatma.
/// [scope]: silme/projeye eklemeden sonra hangi liste tazelenecek.
Future<void> showAiStudioViewer(
  BuildContext context, {
  required List<AiStudioImage> images,
  int initialIndex = 0,
  AiStudioScope scope = AiStudioScope.mine,
}) {
  assert(images.isNotEmpty);
  return Navigator.of(context, rootNavigator: true).push<void>(PageRouteBuilder<void>(
    opaque: false,
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, _, _) => AiStudioViewer(images: images, initialIndex: initialIndex, scope: scope),
    transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
  ));
}

const kAiStudioRefineStarted = 'Yeni görsel hazırlanıyor; hazır olunca haber verilir.';

const _kDismissDistance = 120.0;
const _kDismissVelocity = 900.0;

class AiStudioViewer extends ConsumerStatefulWidget {
  const AiStudioViewer({super.key, required this.images, this.initialIndex = 0, this.scope = AiStudioScope.mine});

  final List<AiStudioImage> images;
  final int initialIndex;
  final AiStudioScope scope;

  @override
  ConsumerState<AiStudioViewer> createState() => _AiStudioViewerState();
}

class _AiStudioViewerState extends ConsumerState<AiStudioViewer> with SingleTickerProviderStateMixin {
  late final List<AiStudioImage> _images = List.of(widget.images);
  late int _index = widget.initialIndex.clamp(0, _images.length - 1);
  late final PageController _pages = PageController(initialPage: _index);
  bool _zoomed = false;
  int _pointers = 0;
  bool _busy = false;
  bool _chrome = true;
  double _dismissDy = 0;
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  double _settleFrom = 0;

  AiStudioImage get _current => _images[_index];

  @override
  void initState() {
    super.initState();
    _settle.addListener(() => setState(() => _dismissDy = _settleFrom * (1 - Curves.easeOut.transform(_settle.value))));
  }

  @override
  void dispose() {
    _settle.dispose();
    _pages.dispose();
    super.dispose();
  }

  void _onDismissDrag(double dy) {
    _settle.stop();
    setState(() => _dismissDy += dy);
  }

  void _onDismissEnd(double? velocity) {
    if (velocity != null && (_dismissDy.abs() > _kDismissDistance || velocity.abs() > _kDismissVelocity)) {
      Navigator.of(context).pop();
      return;
    }
    _settleFrom = _dismissDy;
    _settle.forward(from: 0);
  }

  void _toast(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));

  /// iOS paylaşım menüsünde "Görüntüyü Kaydet" de var: telefona kaydetmek
  /// için ayrı bir fotoğraf arşivi izni/paketi eklenmedi.
  Future<void> _share() async {
    final image = _current;
    final bytes = ref.read(aiStudioImageBytesProvider(image.id)).valueOrNull;
    if (bytes == null) return;
    try {
      final ext = image.mime == 'image/png' ? 'png' : 'jpg';
      final error = await ref
          .read(fileSharerProvider)
          .shareFile('yapay-zeka-${image.id}.$ext', bytes, mimeType: image.mime);
      if (error != null && mounted) _toast(error);
    } on Exception catch (e, s) {
      if (mounted) showDeviceIssue(context, ref, e, s, DeviceAction.saveFile, where: 'Yapay zekâ görseli paylaşımı');
    }
  }

  Future<void> _addToProject() async {
    final image = _current;
    final project = await showProjectPickerSheet(context);
    if (project == null || !mounted) return;
    final stage = await showAppSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _StageSheet(project: project, initial: image.kind == AiImageKind.beforeAfter ? 'after' : 'progress'),
    );
    if (stage == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final photoId = await ref
          .read(aiStudioRepositoryProvider)
          .addToProject(image.id, projectId: project.id, stage: stage);
      ref.invalidate(projectPhotosProvider(project.id));
      final updated = image.withProject(
        AiStudioImageProject(projectId: project.id, projectName: project.name, projectPhotoId: photoId),
      );
      ref.read(aiStudioImagesProvider(widget.scope).notifier).replaceLocal(updated);
      if (!mounted) return;
      setState(() {
        _images[_images.indexWhere((i) => i.id == image.id)] = updated;
        _busy = false;
      });
      _toast('Projeye eklendi: ${project.name}');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(e.message);
    }
  }

  /// "Gelen resme düzenleme olsun": sonuç yeni bir görsel olarak gelir,
  /// bu görsel kalır. Görüntüleyici açık kalır; hazır olunca kökteki bant
  /// ("Görsel hazır · Göster") yenisini açar.
  Future<void> _refine() async {
    if (await showAiStudioRefineSheet(context, _current.id) && mounted) {
      _toast(kAiStudioRefineStarted);
    }
  }

  Future<void> _delete() async {
    final image = _current;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Görseli Sil'),
        content: Text(image.projects.isEmpty
            ? 'Bu görsel silinsin mi?'
            : 'Bu görsel Görsellerim\'den silinsin mi? Eklendiği projelerdeki kopyası kalır.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(aiStudioRepositoryProvider).delete(image.id);
      unawaited(ref.read(projectPhotoCacheProvider).remove(image.id));
      ref.read(aiStudioImagesProvider(widget.scope).notifier).removeLocal(image.id);
      if (!mounted) return;
      if (_images.length == 1) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _images.removeAt(_index);
        if (_index >= _images.length) _index = _images.length - 1;
        _zoomed = false;
        _busy = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pages.hasClients && _pages.page?.round() != _index) _pages.jumpToPage(_index);
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _current;
    final hasBytes = ref.watch(aiStudioImageBytesProvider(image.id)).hasValue;
    final fade = (1 - _dismissDy.abs() / 400).clamp(0.0, 1.0);
    final chromeOpacity = _chrome && _dismissDy == 0 ? 1.0 : 0.0;
    final canPage = !_zoomed && _pointers < 2 && !_busy;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: Colors.black.withValues(alpha: fade))),
            Positioned.fill(
              child: Listener(
                onPointerDown: (_) => setState(() => _pointers++),
                onPointerUp: (_) => setState(() => _pointers = (_pointers - 1).clamp(0, 10)),
                onPointerCancel: (_) => setState(() => _pointers = (_pointers - 1).clamp(0, 10)),
                child: Transform.translate(
                  offset: Offset(0, _dismissDy),
                  child: PageView.builder(
                    key: const ValueKey('ai-studio-viewer-pages'),
                    controller: _pages,
                    physics: canPage ? null : const NeverScrollableScrollPhysics(),
                    allowImplicitScrolling: true,
                    onPageChanged: (i) => setState(() {
                      _index = i;
                      _zoomed = false;
                    }),
                    itemCount: _images.length,
                    findChildIndexCallback: (key) {
                      final i = _images.indexWhere((p) => ValueKey('ai-studio-viewer-${p.id}') == key);
                      return i < 0 ? null : i;
                    },
                    itemBuilder: (context, i) {
                      final id = _images[i].id;
                      return GalleryZoomPage(
                        key: ValueKey('ai-studio-viewer-$id'),
                        bytes: aiStudioImageBytesProvider(id),
                        onRetry: () => ref.invalidate(aiStudioImageBytesProvider(id)),
                        onZoomChanged: (z) {
                          if (id == _current.id && z != _zoomed) setState(() => _zoomed = z);
                        },
                        onTap: () => setState(() => _chrome = !_chrome),
                        onDismissDrag: _onDismissDrag,
                        onDismissEnd: _onDismissEnd,
                      );
                    },
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: IgnorePointer(
                ignoring: chromeOpacity == 0,
                child: AnimatedOpacity(
                  opacity: chromeOpacity,
                  duration: const Duration(milliseconds: 150),
                  child: AppBar(
                    backgroundColor: Colors.black.withValues(alpha: 0.45),
                    foregroundColor: Colors.white,
                    surfaceTintColor: Colors.transparent,
                    elevation: 0,
                    systemOverlayStyle: SystemUiOverlayStyle.light,
                    title: Text(
                      '${_index + 1} / ${_images.length}',
                      key: const ValueKey('ai-studio-viewer-counter'),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                    actions: [
                      IconButton(
                        icon: const Icon(Icons.share_outlined),
                        tooltip: 'Paylaş / Kaydet',
                        onPressed: !hasBytes || _busy ? null : _share,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: chromeOpacity == 0,
                child: AnimatedOpacity(
                  opacity: chromeOpacity,
                  duration: const Duration(milliseconds: 150),
                  child: _Caption(
                    image: image,
                    showOwner: widget.scope == AiStudioScope.firm,
                    busy: _busy,
                    onRefine: _refine,
                    onAddToProject: _addToProject,
                    onShare: hasBytes ? _share : null,
                    onDelete: _delete,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Alt açıklama: rozet, tür, açıklama, tarih (firma görünümünde kimin),
/// eklendiği projeler ve etiketli işlemler -- etiketsiz simge keşfedilmiyor.
class _Caption extends StatelessWidget {
  const _Caption({
    required this.image,
    required this.showOwner,
    required this.busy,
    required this.onRefine,
    required this.onAddToProject,
    required this.onShare,
    required this.onDelete,
  });

  final AiStudioImage image;
  final bool showOwner;
  final bool busy;
  final VoidCallback onRefine;
  final VoidCallback onAddToProject;
  final VoidCallback? onShare;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final date = image.createdAt.isEmpty ? '' : Formatters.dateTime(image.createdAt);
    final meta = [
      if (date.isNotEmpty) date,
      if (showOwner && image.userName.trim().isNotEmpty) image.userName.trim(),
    ].join(' · ');
    final projects = [for (final p in image.projects) if (p.projectName.trim().isNotEmpty) p.projectName.trim()];
    final buttonStyle = TextButton.styleFrom(foregroundColor: Colors.white, visualDensity: VisualDensity.compact);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xDD000000), Color(0x00000000)],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xl, AppSpacing.sm, AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const AiBadge(),
                  Text(
                    aiKindLabel(image.kind),
                    style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              if (image.prompt.trim().isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  image.prompt.trim(),
                  key: const ValueKey('ai-studio-viewer-prompt'),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  maxLines: landscape ? 2 : 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (meta.isNotEmpty) Text(meta, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              if (projects.isNotEmpty)
                Text(
                  'Projede: ${projects.join(', ')}',
                  key: const ValueKey('ai-studio-viewer-projects'),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              const SizedBox(height: AppSpacing.xs),
              // Wrap: 320 pt'de ve büyük yazıda düğmeler alt satıra iner.
              Wrap(
                spacing: AppSpacing.xs,
                children: [
                  TextButton.icon(
                    key: const ValueKey('ai-studio-refine'),
                    style: buttonStyle,
                    onPressed: busy ? null : onRefine,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Düzenle'),
                  ),
                  TextButton.icon(
                    key: const ValueKey('ai-studio-add-to-project'),
                    style: buttonStyle,
                    onPressed: busy ? null : onAddToProject,
                    icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
                    label: const Text('Projeye ekle'),
                  ),
                  TextButton.icon(
                    style: buttonStyle,
                    onPressed: busy ? null : onShare,
                    icon: const Icon(Icons.ios_share, size: 18),
                    label: const Text('Paylaş / Kaydet'),
                  ),
                  TextButton.icon(
                    key: const ValueKey('ai-studio-delete'),
                    style: buttonStyle,
                    onPressed: busy ? null : onDelete,
                    icon: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Sil'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Projeye eklerken aşama: Önce / Süreç / Sonra.
class _StageSheet extends StatefulWidget {
  const _StageSheet({required this.project, required this.initial});
  final ProjectOption project;
  final String initial;

  @override
  State<_StageSheet> createState() => _StageSheetState();
}

class _StageSheetState extends State<_StageSheet> {
  late String _stage = widget.initial;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Projeye ekle', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
          const SizedBox(height: AppSpacing.xs),
          Text(formProjectLabel(widget.project.projectNo, widget.project.name), style: AppTypography.body),
          const SizedBox(height: AppSpacing.md),
          const Text('Hangi aşamaya?', style: AppTypography.helper),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              for (final s in kAiStudioStages)
                ChoiceChip(
                  key: ValueKey('ai-studio-stage-${s.code}'),
                  label: Text(s.label),
                  selected: _stage == s.code,
                  onSelected: (_) => setState(() => _stage = s.code),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const Text('Projede "Yapay zekâ" rozetiyle ayrı görünür.', style: AppTypography.helper),
          const SizedBox(height: AppSpacing.md),
          PrimaryButton(
            icon: Icons.add_photo_alternate_outlined,
            label: 'Projeye ekle',
            onPressed: () => Navigator.of(context).pop(_stage),
          ),
        ],
      ),
    );
  }
}
