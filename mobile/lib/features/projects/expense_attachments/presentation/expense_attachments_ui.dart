import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/errors/api_exception.dart';
import '../../../../core/errors/device_errors.dart';
import '../../../../core/files/device_picker.dart';
import '../../../../core/files/local_documents.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/app_sheet.dart';
import '../../data/projects_providers.dart' show projectExpensesProvider;
import '../../domain/expense_attachment.dart';
import '../../domain/project.dart' show Expense, exceedsMaxUploadBytes;
import '../../my_expenses/data/my_expenses_repository.dart' show allExpensesProvider, myExpensesProvider;
import '../data/expense_attachments_repository.dart';

/// Masraf fişi / belgesi (backend migration 0076, kullanıcı geri bildirimi:
/// "masraf girme yerine resim ve dosya ekleme gibi bir yer olsun"):
///   - formda "Fiş / Belge" bölümü: Fotoğraf çek / Galeriden seç / Dosya seç,
///     küçük resimler, kaydetmeden önce kaldırma; dosyalar masraf
///     kaydedildikten SONRA yüklenir (bkz. [uploadExpenseFiles]);
///   - masraf ayrıntısında belgeler: fotoğrafa dokununca tam ekran, PDF
///     telefonun görüntüleyicisinde; giren (bekleyen/reddedilen masrafında)
///     ve finans yöneticisi ekler/kaldırır; yüklenemeyenler "Tekrar dene".

/// Belgenin nereden alınacağı.
enum ExpenseAttachmentSource { camera, gallery, file }

const _kOutsideTypesText = 'Yalnızca fotoğraf (JPEG, PNG, HEIC) ya da PDF eklenebilir.';

/// Telefondan bir belge alır; vazgeçilirse ya da dosya uygun değilse null
/// (nedeni kullanıcıya söylenir). Kamera/galeri izin reddi ve seçici
/// hataları `showDeviceIssue` ile anlatılır.
Future<PickedDeviceFile?> pickExpenseAttachment(
  BuildContext context,
  WidgetRef ref,
  ExpenseAttachmentSource source,
) async {
  final picker = ref.read(devicePickerProvider);
  final action = switch (source) {
    ExpenseAttachmentSource.camera => DeviceAction.camera,
    ExpenseAttachmentSource.gallery => DeviceAction.gallery,
    ExpenseAttachmentSource.file => DeviceAction.pickFile,
  };
  final PickedDeviceFile? picked;
  final int size;
  try {
    picked = switch (source) {
      ExpenseAttachmentSource.camera => await picker.pickImage(ImageSource.camera),
      ExpenseAttachmentSource.gallery => await picker.pickImage(ImageSource.gallery),
      ExpenseAttachmentSource.file => await picker.pickFile(),
    };
    if (picked == null) return null;
    size = picked.size ?? await File(picked.path).length();
  } on Exception catch (e, s) {
    if (context.mounted) showDeviceIssue(context, ref, e, s, action, where: 'Masraf belgesi');
    return null;
  }
  void say(String message) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // Kamera/galeri her zaman fotoğraf verir (uygulama HEIC'i JPEG'e çevirir);
  // dosya seçici her şeyi seçtirir -- yanlış türü yüklemeden söyle.
  if (source == ExpenseAttachmentSource.file && !isAcceptedExpenseAttachmentName(picked.name)) {
    say(_kOutsideTypesText);
    return null;
  }
  if (exceedsMaxUploadBytes(size, AppConfig.maxUploadBytes)) {
    say('Dosya 25 MiB sınırını aşıyor (${Formatters.fileSize(size)}).');
    return null;
  }
  return (path: picked.path, name: picked.name, size: size);
}

/// Yükleme sonucu: yüklenenler, yüklenemeyenler ve ilk hatanın metni.
typedef ExpenseUploadOutcome = ({List<ExpenseAttachment> uploaded, List<PickedDeviceFile> failed, String? firstError});

/// Dosyaları sırayla yükler; biri yüklenemezse diğerleri yine denenir.
/// [onProgress]: (kaçıncı dosya, toplam, o dosyanın gönderilen oranı).
Future<ExpenseUploadOutcome> uploadExpenseFiles(
  ExpenseAttachmentsRepository repo,
  String projectId,
  String expenseId,
  List<PickedDeviceFile> files, {
  void Function(int index, int total, double fraction)? onProgress,
}) async {
  final uploaded = <ExpenseAttachment>[];
  final failed = <PickedDeviceFile>[];
  String? firstError;
  for (var i = 0; i < files.length; i++) {
    onProgress?.call(i, files.length, 0);
    try {
      uploaded.add(
        await repo.upload(
          projectId,
          expenseId,
          filePath: files[i].path,
          fileName: files[i].name,
          onSendProgress: (sent, total) => onProgress?.call(i, files.length, total > 0 ? sent / total : 0),
        ),
      );
    } on ApiException catch (e) {
      failed.add(files[i]);
      firstError ??= e.message;
    } on Exception {
      // Dosya bu arada silindi/okunamadı (geçici kopya temizlendi).
      failed.add(files[i]);
      firstError ??= 'Dosya okunamadı.';
    }
  }
  return (uploaded: uploaded, failed: failed, firstError: firstError);
}

/// Masraf listeleri (kartlardaki ataş sayısı) belge değişince tazelenir.
void _invalidateExpenseLists(WidgetRef ref, String projectId) {
  ref.invalidate(myExpensesProvider);
  ref.invalidate(allExpensesProvider);
  if (projectId.isNotEmpty) ref.invalidate(projectExpensesProvider(projectId));
}

/// Kaynak seçimi (masraf ayrıntısındaki "Belge ekle").
Future<ExpenseAttachmentSource?> _askSource(BuildContext context) => showAppSheet<ExpenseAttachmentSource>(
  context: context,
  useSafeArea: true,
  builder: (context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.photo_camera_outlined),
          title: const Text('Fotoğraf çek'),
          onTap: () => Navigator.of(context).pop(ExpenseAttachmentSource.camera),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library_outlined),
          title: const Text('Galeriden seç'),
          onTap: () => Navigator.of(context).pop(ExpenseAttachmentSource.gallery),
        ),
        ListTile(
          leading: const Icon(Icons.picture_as_pdf_outlined),
          title: const Text('Dosya seç (PDF)'),
          onTap: () => Navigator.of(context).pop(ExpenseAttachmentSource.file),
        ),
      ],
    ),
  ),
);

// ============================================================ form

/// Masraf formundaki "Fiş / Belge" bölümü: seçilen (henüz yüklenmemiş)
/// dosyalar ve üç kaynak düğmesi. Yükleme masraf kaydedilince formda.
class ExpenseAttachmentPickerField extends ConsumerWidget {
  const ExpenseAttachmentPickerField({super.key, required this.files, required this.onChanged, this.enabled = true});

  final List<PickedDeviceFile> files;
  final ValueChanged<List<PickedDeviceFile>> onChanged;
  final bool enabled;

  Future<void> _add(BuildContext context, WidgetRef ref, ExpenseAttachmentSource source) async {
    final picked = await pickExpenseAttachment(context, ref, source);
    if (picked == null) return;
    // Aynı dosya iki kez seçildiyse bir kez yüklenir.
    if (files.any((f) => f.path == picked.path)) return;
    onChanged([...files, picked]);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final full = files.length >= kExpenseAttachmentsMax;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (files.isNotEmpty) ...[
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (var i = 0; i < files.length; i++)
                _PendingTile(
                  key: ValueKey('masraf-belge-secilen-$i'),
                  file: files[i],
                  onRemove: enabled ? () => onChanged([...files]..removeAt(i)) : null,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (!full)
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              TextButton.icon(
                key: const ValueKey('masraf-belge-kamera'),
                onPressed: enabled ? () => _add(context, ref, ExpenseAttachmentSource.camera) : null,
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('Fotoğraf çek'),
              ),
              TextButton.icon(
                key: const ValueKey('masraf-belge-galeri'),
                onPressed: enabled ? () => _add(context, ref, ExpenseAttachmentSource.gallery) : null,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Galeriden seç'),
              ),
              TextButton.icon(
                key: const ValueKey('masraf-belge-dosya'),
                onPressed: enabled ? () => _add(context, ref, ExpenseAttachmentSource.file) : null,
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('Dosya seç'),
              ),
            ],
          ),
        Text(
          full
              ? 'Bir masrafa en fazla $kExpenseAttachmentsMax belge eklenebilir.'
              : 'Fişin ya da faturanın fotoğrafını çek veya PDF ekle; masraf kaydedilince yüklenir.',
          style: AppTypography.helper,
        ),
      ],
    );
  }
}

/// Seçilen dosyanın küçük resmi (fotoğraf) ya da belge simgesi + "Kaldır".
class _PendingTile extends StatelessWidget {
  const _PendingTile({super.key, required this.file, required this.onRemove});

  final PickedDeviceFile file;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return _TileFrame(
      label: file.name,
      onRemove: onRemove,
      removeKey: ValueKey('masraf-belge-kaldir-${file.name}'),
      child: isImageFileName(file.name)
          ? Image.file(
              File(file.path),
              fit: BoxFit.cover,
              cacheWidth: (_kTileSize * dpr).ceil(),
              errorBuilder: (_, _, _) => const _DocIcon(icon: Icons.image_outlined),
            )
          : const _DocIcon(icon: Icons.picture_as_pdf_outlined),
    );
  }
}

// ============================================================ ayrıntı

/// Masraf ayrıntısındaki belgeler. [canManage]: ekleme/kaldırma (giren --
/// bekleyen/reddedilen masrafında -- ve finans yöneticisi; onaylı/iptal
/// masrafta salt okunur, sunucu da 409 verir). Belge listesi masrafın
/// liste satırından gelir; sunucu bu yanıtta belge göndermediyse
/// (`attachments == null`) ve yüklenemeyen belge yoksa bölüm gösterilmez.
class ExpenseAttachmentsSection extends ConsumerStatefulWidget {
  const ExpenseAttachmentsSection({super.key, required this.projectId, required this.expense, required this.canManage});

  final String projectId;
  final Expense expense;
  final bool canManage;

  @override
  ConsumerState<ExpenseAttachmentsSection> createState() => _ExpenseAttachmentsSectionState();
}

class _ExpenseAttachmentsSectionState extends ConsumerState<ExpenseAttachmentsSection> {
  late final List<ExpenseAttachment> _items = [...?widget.expense.attachments];
  bool _busy = false;
  double? _progress;
  String? _openingId;
  String? _error;

  String get _expenseId => widget.expense.id;

  void _say(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _upload(List<PickedDeviceFile> files, {bool retry = false}) async {
    setState(() {
      _busy = true;
      _progress = 0;
      _error = null;
    });
    final outcome = await uploadExpenseFiles(
      ref.read(expenseAttachmentsRepositoryProvider),
      widget.projectId,
      _expenseId,
      files,
      onProgress: (i, n, f) {
        if (mounted) setState(() => _progress = (i + f) / n);
      },
    );
    if (!mounted) return;
    final failedStore = ref.read(failedExpenseUploadsProvider.notifier);
    for (final f in files) {
      if (!outcome.failed.contains(f)) failedStore.remove(_expenseId, f);
    }
    if (!retry) failedStore.add(_expenseId, outcome.failed);
    setState(() {
      _busy = false;
      _progress = null;
      for (final a in outcome.uploaded) {
        if (!_items.any((x) => x.id == a.id)) _items.add(a);
      }
      _error = outcome.firstError;
    });
    if (outcome.uploaded.isNotEmpty) _invalidateExpenseLists(ref, widget.projectId);
  }

  Future<void> _add() async {
    final source = await _askSource(context);
    if (source == null || !mounted) return;
    final picked = await pickExpenseAttachment(context, ref, source);
    if (picked == null || !mounted) return;
    await _upload([picked]);
  }

  Future<void> _delete(ExpenseAttachment a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Belgeyi Kaldır'),
        content: Text('"${a.localName}" masraftan kaldırılsın mı? Bu işlem geri alınmaz.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Kaldır')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(expenseAttachmentsRepositoryProvider).delete(widget.projectId, _expenseId, a.id);
      await ref.read(expenseAttachmentCacheProvider).remove(a.id);
      if (!mounted) return;
      setState(() => _items.removeWhere((x) => x.id == a.id));
      _invalidateExpenseLists(ref, widget.projectId);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(ExpenseAttachment a) async {
    if (a.isDisplayableImage) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ExpenseAttachmentViewerScreen(projectId: widget.projectId, attachment: a),
        ),
      );
      return;
    }
    setState(() => _openingId = a.id);
    try {
      final bytes = await ref.read(expenseAttachmentsRepositoryProvider).bytes(widget.projectId, _expenseId, a.id);
      if (!mounted) return;
      final error = await ref.read(documentOpenerProvider)(a.localName, bytes, mimeType: a.mimeType);
      if (error != null) _say(error);
    } on ApiException catch (e) {
      _say(e.message);
    } on Exception catch (e, s) {
      if (mounted) showDeviceIssue(context, ref, e, s, DeviceAction.saveFile, where: 'Masraf belgesi');
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final failed = ref.watch(failedExpenseUploadsProvider)[_expenseId] ?? const <PickedDeviceFile>[];
    if (widget.expense.attachments == null && failed.isEmpty && _items.isEmpty) return const SizedBox.shrink();
    final canAdd = widget.canManage && _items.length < kExpenseAttachmentsMax;
    return Padding(
      key: const ValueKey('masraf-belgeler'),
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_items.isEmpty ? 'Fiş / Belge' : 'Fiş / Belge (${_items.length})', style: AppTypography.cardTitle),
          const SizedBox(height: AppSpacing.sm),
          if (_items.isEmpty && failed.isEmpty)
            const Text('Fiş veya belge eklenmemiş.', style: AppTypography.helper)
          else if (_items.isNotEmpty)
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final a in _items)
                  _AttachmentTile(
                    key: ValueKey('masraf-belge-${a.id}'),
                    projectId: widget.projectId,
                    attachment: a,
                    opening: _openingId == a.id,
                    onTap: _busy ? null : () => _open(a),
                    onRemove: widget.canManage && !_busy ? () => _delete(a) : null,
                  ),
              ],
            ),
          for (final f in failed)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      '${f.name} yüklenemedi',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.metadata.copyWith(color: AppColors.danger),
                    ),
                  ),
                  if (widget.canManage)
                    TextButton(
                      key: ValueKey('masraf-belge-tekrar-${f.name}'),
                      onPressed: _busy ? null : () => _upload([f], retry: true),
                      child: const Text('Tekrar dene'),
                    ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => ref.read(failedExpenseUploadsProvider.notifier).remove(_expenseId, f),
                    child: const Text('Vazgeç'),
                  ),
                ],
              ),
            ),
          if (_busy && _progress != null) ...[
            const SizedBox(height: AppSpacing.sm),
            LinearProgressIndicator(value: _progress),
          ],
          if (_error != null) ...[const SizedBox(height: AppSpacing.sm), Text(_error!, style: AppTypography.error)],
          if (canAdd)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('masraf-belge-ekle'),
                onPressed: _busy ? null : _add,
                icon: const Icon(Icons.attach_file),
                label: const Text('Belge ekle'),
              ),
            ),
        ],
      ),
    );
  }
}

const double _kTileSize = 76;

/// Sunucudaki belgenin kutucuğu: fotoğrafta küçük resim (bayt çerezli
/// istemciden, cihaz önbelleğiyle), PDF/HEIC'te simge ve ad.
class _AttachmentTile extends ConsumerWidget {
  const _AttachmentTile({
    super.key,
    required this.projectId,
    required this.attachment,
    required this.opening,
    required this.onTap,
    required this.onRemove,
  });

  final String projectId;
  final ExpenseAttachment attachment;
  final bool opening;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = attachment;
    final Widget content;
    if (a.isDisplayableImage) {
      final bytes = ref.watch(
        expenseAttachmentBytesProvider((projectId: projectId, expenseId: a.expenseId, attachmentId: a.id)),
      );
      final dpr = MediaQuery.devicePixelRatioOf(context);
      content = bytes.when(
        data: (b) => Image.memory(
          b,
          fit: BoxFit.cover,
          cacheWidth: (_kTileSize * dpr).ceil(),
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const _DocIcon(icon: Icons.broken_image_outlined),
        ),
        loading: () =>
            const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
        error: (_, _) => const _DocIcon(icon: Icons.broken_image_outlined),
      );
    } else {
      content = opening
          ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
          : _DocIcon(icon: a.isImage ? Icons.image_outlined : Icons.picture_as_pdf_outlined);
    }
    return _TileFrame(
      label: a.localName,
      onTap: onTap,
      onRemove: onRemove,
      removeKey: ValueKey('masraf-belge-kaldir-${a.id}'),
      child: content,
    );
  }
}

/// Kutucuk çerçevesi: içerik, altta ad, köşede "Kaldır" (çöp kutusu).
class _TileFrame extends StatelessWidget {
  const _TileFrame({required this.label, required this.child, this.onTap, this.onRemove, this.removeKey});

  final String label;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final Key? removeKey;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _kTileSize,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              GestureDetector(
                onTap: onTap,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  child: Container(width: _kTileSize, height: _kTileSize, color: AppColors.background, child: child),
                ),
              ),
              if (onRemove != null)
                Positioned(
                  right: 2,
                  top: 2,
                  child: Material(
                    color: AppColors.surface.withValues(alpha: 0.9),
                    shape: const CircleBorder(),
                    child: InkWell(
                      key: removeKey,
                      customBorder: const CircleBorder(),
                      onTap: onRemove,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.delete_outline, size: 16, color: AppColors.danger, semanticLabel: 'Kaldır'),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTypography.helper),
        ],
      ),
    );
  }
}

class _DocIcon extends StatelessWidget {
  const _DocIcon({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) => Center(child: Icon(icon, color: AppColors.textMuted, size: 30));
}

/// Fişin tam ekran görünümü (yakınlaştırılabilir).
class ExpenseAttachmentViewerScreen extends ConsumerWidget {
  const ExpenseAttachmentViewerScreen({super.key, required this.projectId, required this.attachment});

  final String projectId;
  final ExpenseAttachment attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(
      expenseAttachmentBytesProvider((
        projectId: projectId,
        expenseId: attachment.expenseId,
        attachmentId: attachment.id,
      )),
    );
    return Scaffold(
      key: const ValueKey('masraf-belge-tam-ekran'),
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(attachment.localName, style: const TextStyle(fontSize: 14)),
      ),
      body: Center(
        child: bytes.when(
          // Ekranın ~2 katı genişlikte çözülür: yakınlaştırmaya yeter, 12 MP'yi
          // tam açıp yüzlerce MB harcamaz (şantiye fotoğrafıyla aynı).
          data: (b) => InteractiveViewer(
            child: Image.memory(
              b,
              cacheWidth: (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context) * 2).ceil(),
              errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined, color: Colors.white, size: 48),
            ),
          ),
          loading: () => const CircularProgressIndicator(color: Colors.white),
          error: (_, _) => const Icon(Icons.broken_image_outlined, color: Colors.white, size: 48),
        ),
      ),
    );
  }
}
