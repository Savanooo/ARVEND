import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/errors/device_errors.dart';
import '../../../core/files/file_share.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/projects_providers.dart';
import '../domain/project.dart';

/// Galeriyi [photos] listesinin [initialIndex]'inde, tam ekran açar. Liste
/// ızgaranın gösterdiği SIRADA verilir (bkz. sortPhotosByStage): sağa/sola
/// kaydırınca aşamalar arası bütün fotoğraflar o sırayla gezilir. Eskiden
/// tek fotoğraf açılıyordu; sonrakine geçmek için kapatıp ızgaradan yeniden
/// seçmek gerekiyordu ("resimler sıra sıra kaymıyor, galeri değil").
///
/// Kök navigator'a basılır: proje ekranı alt menülü kabuğun içinde, galeri
/// alt menünün üstünü de kaplamalı. Rota opak değil: aşağı kaydırırken
/// arkadaki ekran belirir, kapanacağı belli olur.
///
/// [canDelete]: silme düğmeleri (projects.operations.manage). [onDeleted]:
/// silinen her fotoğraf için -- çağıran kendi listesini (ör. günlük rapor)
/// tazelesin; proje fotoğraf listesini galeri kendisi tazeler.
Future<void> showProjectPhotoGallery(
  BuildContext context, {
  required String projectId,
  required List<ProjectPhoto> photos,
  int initialIndex = 0,
  bool canDelete = false,
  ValueChanged<ProjectPhoto>? onDeleted,
}) {
  assert(photos.isNotEmpty);
  return Navigator.of(context, rootNavigator: true).push<void>(PageRouteBuilder<void>(
    opaque: false,
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, _, _) => ProjectPhotoGalleryScreen(
      projectId: projectId,
      photos: photos,
      initialIndex: initialIndex,
      canDelete: canDelete,
      onDeleted: onDeleted,
    ),
    transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
  ));
}

/// Tam ekran fotoğraf galerisi. Hareketler:
/// - 1x'te yatay kaydırma sayfa değiştirir, dikey kaydırma galeriyi kapatır.
/// - İki parmak ya da çift dokunuş yakınlaştırır; yakınken kaydırma
///   fotoğrafın İÇİNDE gezdirir, sayfa DEĞİŞMEZ (ikisi aynı anda çalışınca
///   yakın fotoğrafta gezinirken sayfa kayıyordu). Uzaklaşınca (çift dokunuş
///   ya da iki parmak) kaydırma yeniden sayfa değiştirir.
/// - Tek dokunuş üst çubuğu ve açıklamayı gizler/gösterir (yatay ekranda ve
///   küçük telefonda fotoğrafa yer açar).
///
/// Paylaş ve Sil o an GÖRÜNEN fotoğrafa uygulanır; silinenin yerine
/// sıradaki gelir (sondaysa bir önceki), son fotoğraf silinince kapanır.
class ProjectPhotoGalleryScreen extends ConsumerStatefulWidget {
  const ProjectPhotoGalleryScreen({
    super.key,
    required this.projectId,
    required this.photos,
    this.initialIndex = 0,
    this.canDelete = false,
    this.onDeleted,
  });

  final String projectId;
  final List<ProjectPhoto> photos;
  final int initialIndex;
  final bool canDelete;
  final ValueChanged<ProjectPhoto>? onDeleted;

  @override
  ConsumerState<ProjectPhotoGalleryScreen> createState() => _ProjectPhotoGalleryScreenState();
}

/// Bu kadar (dp) aşağı/yukarı sürüklenip bırakılınca galeri kapanır; daha
/// azında yerine yaylanır. Hızlı bir fiske de kapatır.
const _kDismissDistance = 120.0;
const _kDismissVelocity = 900.0;

class _ProjectPhotoGalleryScreenState extends ConsumerState<ProjectPhotoGalleryScreen>
    with SingleTickerProviderStateMixin {
  late final List<ProjectPhoto> _photos = List.of(widget.photos);
  late int _index = widget.initialIndex.clamp(0, _photos.length - 1);
  late final PageController _pages = PageController(initialPage: _index);

  /// Görünen fotoğraf yakınlaştırılmış: sayfa kaydırma kapalı, sürükleme
  /// fotoğrafın içinde gezdirir.
  bool _zoomed = false;

  /// Ekrana iki parmak değdi: sıkıştırma hareketini sayfa kaydırma
  /// kapmasın (iki parmak yatayda açılınca PageView onu kaydırma sanıyordu).
  int _pointers = 0;
  bool _deleting = false;
  bool _chrome = true;

  /// Kapatmak için dikey sürükleme mesafesi (dp); bırakınca yaylanarak 0'a döner.
  double _dismissDy = 0;
  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  double _settleFrom = 0;

  ProjectPhoto get _current => _photos[_index];

  ProjectPhotoKey _keyOf(ProjectPhoto photo) => (projectId: widget.projectId, photoId: photo.id);

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

  void _onPageChanged(int i) {
    if (i < 0 || i >= _photos.length) return;
    setState(() {
      _index = i;
      _zoomed = false;
    });
  }

  void _onZoomChanged(String photoId, bool zoomed) {
    if (photoId != _current.id || zoomed == _zoomed) return;
    setState(() => _zoomed = zoomed);
  }

  void _onDismissDrag(double dy) {
    _settle.stop();
    setState(() => _dismissDy += dy);
  }

  /// [velocity] null: sürükleme kapatma değilmiş (ikinci parmak değdi) --
  /// mesafe ne olursa olsun yerine döner.
  void _onDismissEnd(double? velocity) {
    if (velocity != null && (_dismissDy.abs() > _kDismissDistance || velocity.abs() > _kDismissVelocity)) {
      Navigator.of(context).pop();
      return;
    }
    _settleFrom = _dismissDy;
    _settle.forward(from: 0);
  }

  Future<void> _share(Uint8List bytes) async {
    final photo = _current;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final name = photo.originalName.trim().isEmpty ? '${photo.id}.jpg' : photo.originalName.trim();
      final error = await ref
          .read(fileSharerProvider)
          .shareFile(name, bytes, mimeType: photo.mimeType, text: photo.description);
      if (error != null) messenger.showSnackBar(SnackBar(content: Text(error)));
    } on Exception catch (e, s) {
      if (mounted) showDeviceIssue(context, ref, e, s, DeviceAction.saveFile, where: 'Proje fotoğrafı paylaşımı');
    }
  }

  Future<void> _delete() async {
    final photo = _current;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Fotoğrafı Sil'),
        content: const Text('Bu fotoğraf silinsin mi?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // İstek sürerken sayfa kaydırılamaz: silinen, görünen fotoğraf olarak kalsın.
    setState(() => _deleting = true);
    try {
      await ref.read(projectsRepositoryProvider).deletePhoto(widget.projectId, photo.id);
      unawaited(ref.read(projectPhotoCacheProvider).remove(photo.id));
      ref.invalidate(projectPhotosProvider(widget.projectId));
      widget.onDeleted?.call(photo);
      if (!mounted) return;
      if (_photos.length == 1) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _photos.removeAt(_index);
        // Silinenin yerine sıradaki gelir; silinen sondaysa bir önceki.
        if (_index >= _photos.length) _index = _photos.length - 1;
        _zoomed = false;
        _deleting = false;
      });
      // Son sayfa silindiyse denetleyici artık var olmayan sayfada kalır.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pages.hasClients && _pages.page?.round() != _index) _pages.jumpToPage(_index);
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = _current;
    final bytes = ref.watch(projectPhotoBytesProvider(_keyOf(photo))).valueOrNull;
    // Sürükledikçe arka plan ve çubuklar silikleşir, arkadaki ekran belirir.
    final fade = (1 - _dismissDy.abs() / 400).clamp(0.0, 1.0);
    final chromeOpacity = _chrome && _dismissDy == 0 ? 1.0 : 0.0;
    final canPage = !_zoomed && _pointers < 2 && !_deleting;
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
                    key: const ValueKey('photo-gallery-pages'),
                    controller: _pages,
                    physics: canPage ? null : const NeverScrollableScrollPhysics(),
                    // Komşu sayfalar ekran dışında önceden kurulur: baytları
                    // (önce cihaz önbelleğinden) gelir ve çözülür, kaydırınca
                    // fotoğraf beklemeden görünür.
                    allowImplicitScrolling: true,
                    onPageChanged: _onPageChanged,
                    itemCount: _photos.length,
                    findChildIndexCallback: (key) {
                      final i = _photos.indexWhere((p) => ValueKey('photo-gallery-${p.id}') == key);
                      return i < 0 ? null : i;
                    },
                    itemBuilder: (context, i) {
                      final p = _photos[i];
                      return _GalleryPage(
                        key: ValueKey('photo-gallery-${p.id}'),
                        photoKey: _keyOf(p),
                        onZoomChanged: (z) => _onZoomChanged(p.id, z),
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
                      '${_index + 1} / ${_photos.length}',
                      key: const ValueKey('photo-gallery-counter'),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                    actions: [
                      IconButton(
                        icon: const Icon(Icons.share_outlined),
                        tooltip: 'Fotoğrafı paylaş',
                        onPressed: bytes == null || _deleting ? null : () => _share(bytes),
                      ),
                      if (widget.canDelete)
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Fotoğrafı sil',
                          onPressed: _deleting ? null : _delete,
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
                    photo: photo,
                    deleting: _deleting,
                    onDelete: widget.canDelete ? _delete : null,
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

/// Alttaki açıklama: aşama, tam açıklama, tarih ve görünür bir "Sil" --
/// silme eskiden yalnızca ızgarada uzun basışla (keşfedilemez) ya da
/// etiketsiz bir simgeyle yapılabiliyordu. Yükleyen kişi gösterilmez:
/// fotoğraf yanıtında yok (bkz. backend photoResponse).
class _Caption extends StatelessWidget {
  const _Caption({required this.photo, required this.deleting, required this.onDelete});

  final ProjectPhoto photo;
  final bool deleting;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final description = photo.description.trim();
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final hasStage = StatusRegistry.photoStage.containsKey(photo.stage);
    final date = photo.createdAt.isEmpty ? '' : Formatters.dateTime(photo.createdAt);
    return DecoratedBox(
      // Açık renkli bir fotoğrafın üstünde de beyaz yazı okunsun.
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xl, AppSpacing.sm, AppSpacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasStage) ...[
                      // Rozet açık zemine göre renkli (yarı saydam ton);
                      // koyu zeminde "İş Öncesi"nin grisi okunmuyordu.
                      DecoratedBox(
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6)),
                        child: StatusRegistry.build(photo.stage, StatusRegistry.photoStage),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                    ],
                    if (description.isNotEmpty)
                      Text(
                        description,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        maxLines: landscape ? 2 : 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (date.isNotEmpty)
                      Text(date, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ),
              if (onDelete != null)
                TextButton.icon(
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  onPressed: deleting ? null : onDelete,
                  icon: deleting
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
        ),
      ),
    );
  }
}

/// Galerinin tek sayfası: kendi yakınlaştırma durumu olan fotoğraf.
class _GalleryPage extends ConsumerStatefulWidget {
  const _GalleryPage({
    super.key,
    required this.photoKey,
    required this.onZoomChanged,
    required this.onTap,
    required this.onDismissDrag,
    required this.onDismissEnd,
  });

  final ProjectPhotoKey photoKey;
  final ValueChanged<bool> onZoomChanged;
  final VoidCallback onTap;
  final ValueChanged<double> onDismissDrag;
  final ValueChanged<double?> onDismissEnd;

  @override
  ConsumerState<_GalleryPage> createState() => _GalleryPageState();
}

const _kDoubleTapScale = 2.5;

class _GalleryPageState extends ConsumerState<_GalleryPage> with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _zoomAnimation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late final _zoomCurve = CurvedAnimation(parent: _zoomAnimation, curve: Curves.easeOut);
  Matrix4Tween? _zoomTween;
  Offset? _doubleTapAt;
  bool _zoomed = false;

  /// Bu sürükleme galeriyi kapatmaya mı gidiyor: 1x'te, tek parmakla
  /// başladıysa. 1x'te fotoğraf ekrana zaten sığar, kaydırılacak yeri yok.
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransform);
    _zoomAnimation.addListener(() {
      final tween = _zoomTween;
      if (tween != null) _transform.value = tween.evaluate(_zoomCurve);
    });
  }

  @override
  void dispose() {
    _zoomCurve.dispose();
    _zoomAnimation.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _onTransform() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    _zoomed = zoomed;
    widget.onZoomChanged(zoomed);
  }

  /// Çift dokunuş: 1x'teyse dokunulan noktaya yakınlaşır, yakınsa 1x'e döner.
  void _toggleZoom(Size viewport) {
    final Matrix4 target;
    if (_zoomed) {
      target = Matrix4.identity();
    } else {
      final p = _doubleTapAt ?? viewport.center(Offset.zero);
      // p noktası yerinde kalacak şekilde ölçekle: T(p)·S(s)·T(-p).
      target = Matrix4.identity()
        ..translateByDouble(-p.dx * (_kDoubleTapScale - 1), -p.dy * (_kDoubleTapScale - 1), 0, 1)
        ..scaleByDouble(_kDoubleTapScale, _kDoubleTapScale, 1, 1);
    }
    _zoomTween = Matrix4Tween(begin: _transform.value, end: target);
    _zoomAnimation.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final bytesAsync = ref.watch(projectPhotoBytesProvider(widget.photoKey));
    final media = MediaQuery.of(context);
    // Ekranın uzun kenarı kadar (en çok 2400 px) bir kutuya sığdırılarak
    // çözülür: yatay/dikey çevirmede yeniden çözülmez, 2 kat yakınlaşmaya
    // yeter ve 12 MP'lik fotoğraf tam boy açılıp yüzlerce MB harcamaz
    // (görünen + iki komşu sayfa birlikte bellekte).
    final box = (media.size.longestSide * media.devicePixelRatio).clamp(1024.0, 2400.0).ceil();
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        onTap: widget.onTap,
        onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
        onDoubleTap: () => _toggleZoom(constraints.biggest),
        child: InteractiveViewer(
          key: const ValueKey('photo-gallery-zoom'),
          transformationController: _transform,
          minScale: 1,
          maxScale: 4,
          onInteractionStart: (d) {
            _zoomAnimation.stop();
            _dismissing = !_zoomed && d.pointerCount == 1;
          },
          onInteractionUpdate: (d) {
            if (!_dismissing) return;
            // İkinci parmak değdi ya da yakınlaşma başladı: kapatma değil.
            if (d.pointerCount != 1 || _zoomed) {
              _dismissing = false;
              widget.onDismissEnd(null);
              return;
            }
            widget.onDismissDrag(d.focalPointDelta.dy);
          },
          onInteractionEnd: (d) {
            if (!_dismissing) return;
            _dismissing = false;
            widget.onDismissEnd(d.velocity.pixelsPerSecond.dy);
          },
          child: SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: bytesAsync.when(
              data: (bytes) => Image(
                image: ResizeImage(
                  MemoryImage(bytes),
                  width: box,
                  height: box,
                  policy: ResizeImagePolicy.fit,
                ),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const _PhotoProblem(),
              ),
              loading: () => const Center(child: CircularProgressIndicator(color: Colors.white)),
              error: (e, st) => _PhotoProblem(
                onRetry: () => ref.invalidate(projectPhotoBytesProvider(widget.photoKey)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PhotoProblem extends StatelessWidget {
  const _PhotoProblem({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image_outlined, color: Colors.white70, size: 48),
          if (onRetry != null) ...[
            const SizedBox(height: AppSpacing.sm),
            const Text('Fotoğraf yüklenemedi.', style: TextStyle(color: Colors.white70)),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: onRetry,
              child: const Text('Tekrar Dene'),
            ),
          ],
        ],
      ),
    );
  }
}
