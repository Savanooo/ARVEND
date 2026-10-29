import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_sheet.dart';
import '../../projects/data/projects_providers.dart';
import '../../projects/domain/project.dart';
import '../data/ai_images_providers.dart';
import '../domain/ai_image.dart';

const kAiNoticeTitle = 'Yapay zekâ ile görsel';

/// İlk kullanımda bir kez (kişi başına, bu telefonda) gösterilen bilgi.
const kAiPrivacyNotice =
    'Seçtiğiniz fotoğraf ve yazdığınız açıklama, görseli hazırlamak için OpenAI\'ye gönderilir.\n\n'
    'Yapay zekâ görselleri fikir vermek içindir; gerçek şantiye kaydı değildir. '
    'Projede "Yapay zekâ" rozetiyle ayrı gösterilir.';

const kAiPreparingText = 'Hazırlanıyor…';
const kAiLeaveHint = 'Görsel hazır olunca haber verilir; bu pencereyi kapatabilirsiniz.';

/// İlk kullanımdaki bilgilendirme; kabul edilmişse sormadan true.
Future<bool> ensureAiConsent(BuildContext context, WidgetRef ref) async {
  final userId = ref.read(authControllerProvider).valueOrNull?.id ?? '';
  final store = ref.read(aiConsentStoreProvider);
  if (await store.accepted(userId)) return true;
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text(kAiNoticeTitle),
      content: const Text(kAiPrivacyNotice),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Vazgeç')),
        ElevatedButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Anladım, devam et')),
      ],
    ),
  );
  if (ok == true) await store.accept(userId);
  return ok == true;
}

/// Galerideki fotoğraf için: "Bitmiş halini göster" ve "Fotoğrafı iyileştir".
Future<void> showAiPhotoSheet(BuildContext context, {required String projectId, required ProjectPhoto photo}) {
  return showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _AiPhotoSheet(projectId: projectId, photo: photo),
  );
}

/// Proje fotoğrafları bölümünden: açıklamadan yeni görsel, isteğe bağlı
/// referans fotoğrafla.
Future<void> showAiGenerateSheet(BuildContext context, {required String projectId, required List<ProjectPhoto> photos}) {
  return showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _AiGenerateSheet(projectId: projectId, photos: photos),
  );
}

/// İki sayfanın ortak gönderme mantığı: bilgilendirme, iş açma, hata.
mixin _AiSubmit<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool submitting = false;
  String? error;
  bool started = false;

  String get projectId;

  @override
  void initState() {
    super.initState();
    // Kurulum bittikten sonra (build sırasında sağlayıcı değiştirilemez):
    // uygulama yeniden açıldıysa sunucuda süren işler de "Hazırlanıyor"
    // görünsün; kalan hak taze okunsun.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(aiImageJobsProvider.notifier).resume(projectId);
      ref.invalidate(aiImageStatusProvider);
    });
  }

  Future<bool> submit({required String kind, String prompt = '', String? sourcePhotoId}) async {
    if (!await ensureAiConsent(context, ref) || !mounted) return false;
    setState(() {
      submitting = true;
      error = null;
    });
    try {
      await ref
          .read(aiImageJobsProvider.notifier)
          .start(projectId, kind: kind, prompt: prompt.trim(), sourcePhotoId: sourcePhotoId);
      if (mounted) setState(() => started = true);
      return true;
    } on ApiException catch (e) {
      if (mounted) setState(() => error = e.message);
      return false;
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }
}

class _AiPhotoSheet extends ConsumerStatefulWidget {
  const _AiPhotoSheet({required this.projectId, required this.photo});
  final String projectId;
  final ProjectPhoto photo;

  @override
  ConsumerState<_AiPhotoSheet> createState() => _AiPhotoSheetState();
}

class _AiPhotoSheetState extends ConsumerState<_AiPhotoSheet> with _AiSubmit<_AiPhotoSheet> {
  final _prompt = TextEditingController();

  @override
  String get projectId => widget.projectId;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  void _useExample(String example) {
    final current = _prompt.text.trim();
    _prompt.text = current.isEmpty ? example : '$current, ${example[0].toLowerCase()}${example.substring(1)}';
    _prompt.selection = TextSelection.collapsed(offset: _prompt.text.length);
    setState(() {});
  }

  Future<void> _beforeAfter() async {
    if (await submit(kind: AiImageKind.beforeAfter, prompt: _prompt.text, sourcePhotoId: widget.photo.id)) {
      _prompt.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final quota = ref.watch(aiImageStatusProvider).valueOrNull?.quota;
    final noQuota = quota != null && quota.remaining <= 0;
    final busy = submitting || noQuota;
    return _SheetFrame(
      title: 'Yapay zekâ',
      children: [
        Row(
          children: [
            _Thumb(projectId: widget.projectId, photo: widget.photo, size: 56),
            const SizedBox(width: AppSpacing.md),
            const Expanded(
              child: Text('Bu fotoğraftan yeni bir görsel hazırlanır; fotoğrafın kendisi değişmez.',
                  style: AppTypography.helper),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Bitmiş halini göster', style: AppTypography.cardTitle),
        const SizedBox(height: AppSpacing.xs),
        const Text('Müşteriye göstermek için: aynı oda, aynı açı, iş bitmiş gibi.', style: AppTypography.helper),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          key: const ValueKey('ai-before-after-prompt'),
          controller: _prompt,
          maxLength: kAiPromptMaxLength,
          minLines: 2,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Ne yapılacak?',
            hintText: 'ör. Alçıpan asma tavan, spot ışıklı, beyaz boya',
            alignLabelWithHint: true,
            counterText: '',
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            for (final example in kAiBeforeAfterExamples)
              // Sıkı örnekler: 360 dp'de ikişer sığsın, "İyileştir" aşağıda kaybolmasın.
              ActionChip(
                label: Text(example),
                labelStyle: const TextStyle(fontSize: 13),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onPressed: submitting ? null : () => _useExample(example),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        PrimaryButton(
          icon: Icons.auto_awesome,
          label: 'Bitmiş halini göster',
          loading: submitting,
          onPressed: busy || _prompt.text.trim().isEmpty ? null : _beforeAfter,
        ),
        const SizedBox(height: AppSpacing.lg),
        const Divider(height: 1),
        const SizedBox(height: AppSpacing.lg),
        Text('Fotoğrafı iyileştir', style: AppTypography.cardTitle),
        const SizedBox(height: AppSpacing.xs),
        const Text('Karanlık ya da bulanık fotoğrafı aydınlatır ve netleştirir; içerik değişmez.',
            style: AppTypography.helper),
        const SizedBox(height: AppSpacing.sm),
        SecondaryButton(
          icon: Icons.tune,
          label: 'Fotoğrafı iyileştir',
          onPressed: busy ? null : () => submit(kind: AiImageKind.enhance, sourcePhotoId: widget.photo.id),
        ),
        _AiFooter(projectId: widget.projectId, error: error, started: started),
      ],
    );
  }
}

class _AiGenerateSheet extends ConsumerStatefulWidget {
  const _AiGenerateSheet({required this.projectId, required this.photos});
  final String projectId;
  final List<ProjectPhoto> photos;

  @override
  ConsumerState<_AiGenerateSheet> createState() => _AiGenerateSheetState();
}

class _AiGenerateSheetState extends ConsumerState<_AiGenerateSheet> with _AiSubmit<_AiGenerateSheet> {
  final _prompt = TextEditingController();
  String? _referenceId;

  @override
  String get projectId => widget.projectId;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (await submit(kind: AiImageKind.generate, prompt: _prompt.text, sourcePhotoId: _referenceId)) {
      _prompt.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final quota = ref.watch(aiImageStatusProvider).valueOrNull?.quota;
    final noQuota = quota != null && quota.remaining <= 0;
    return _SheetFrame(
      title: 'Yapay zekâ ile görsel oluştur',
      children: [
        TextField(
          key: const ValueKey('ai-generate-prompt'),
          controller: _prompt,
          maxLength: kAiPromptMaxLength,
          minLines: 2,
          maxLines: 5,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Nasıl bir görsel?',
            hintText: 'ör. Banyo seramik, duşakabin, beyaz dolap',
            alignLabelWithHint: true,
            counterText: '',
          ),
        ),
        if (widget.photos.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Text('Referans fotoğraf (isteğe bağlı)', style: AppTypography.cardTitle),
          const SizedBox(height: AppSpacing.xs),
          SizedBox(
            height: 72,
            child: ListView.separated(
              key: const ValueKey('ai-reference-list'),
              scrollDirection: Axis.horizontal,
              itemCount: widget.photos.length + 1,
              separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
              itemBuilder: (context, i) {
                if (i == 0) {
                  return _ReferenceChoice(
                    selected: _referenceId == null,
                    onTap: () => setState(() => _referenceId = null),
                    child: const Center(
                      child: Text('Yok', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textMuted)),
                    ),
                  );
                }
                final photo = widget.photos[i - 1];
                return _ReferenceChoice(
                  key: ValueKey('ai-reference-${photo.id}'),
                  selected: _referenceId == photo.id,
                  onTap: () => setState(() => _referenceId = photo.id),
                  child: _Thumb(projectId: widget.projectId, photo: photo, size: 72),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        PrimaryButton(
          icon: Icons.auto_awesome,
          label: 'Görsel oluştur',
          loading: submitting,
          onPressed: submitting || noQuota || _prompt.text.trim().isEmpty ? null : _generate,
        ),
        _AiFooter(projectId: widget.projectId, error: error, started: started),
      ],
    );
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: AppSpacing.xl,
        right: AppSpacing.xl,
        top: AppSpacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: AppTypography.pageTitle.copyWith(fontSize: 17)),
          const SizedBox(height: AppSpacing.md),
          ...children,
        ],
      ),
    );
  }
}

/// Sunucu hatası, süren işler ("Hazırlanıyor…"), bu ay kalan hak ve
/// Sahip/Yönetici için kişi kişi kullanım.
class _AiFooter extends ConsumerWidget {
  const _AiFooter({required this.projectId, required this.error, required this.started});
  final String projectId;
  final String? error;
  final bool started;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(aiImageJobsProvider);
    final active = ref.read(aiImageJobsProvider.notifier).activeFor(projectId);
    final status = ref.watch(aiImageStatusProvider).valueOrNull;
    final quota = status?.quota;
    final usage = status?.usageByUser;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) ...[
          const SizedBox(height: AppSpacing.md),
          Text(error!, key: const ValueKey('ai-error'), style: AppTypography.error),
        ],
        if (active.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          for (final job in active)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${aiKindLabel(job.kind)} · $kAiPreparingText', style: AppTypography.body),
                  const SizedBox(height: AppSpacing.xs),
                  const LinearProgressIndicator(),
                ],
              ),
            ),
          const Text(kAiLeaveHint, style: AppTypography.helper),
        ],
        if (quota != null) ...[
          const SizedBox(height: AppSpacing.lg),
          Text(
            quota.remaining > 0
                ? 'Bu ay kalan: ${quota.remaining} / ${quota.monthlyLimit} görsel'
                : 'Bu ayın yapay zekâ hakkı doldu (${quota.usedThisMonth} / ${quota.monthlyLimit}). '
                    'Yeni hak ${Formatters.date(quota.resetsAt)} tarihinde açılır.',
            key: const ValueKey('ai-quota'),
            style: quota.remaining > 0 ? AppTypography.metadata : AppTypography.error,
          ),
        ],
        if (usage != null && usage.isNotEmpty)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text('Bu ay firmada kim kullandı', style: AppTypography.metadata),
              children: [
                for (final u in usage)
                  Row(
                    children: [
                      Expanded(child: Text(u.fullName.isEmpty ? 'Silinmiş kullanıcı' : u.fullName, style: AppTypography.body)),
                      Text('${u.images} görsel', style: AppTypography.metadata),
                    ],
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Thumb extends ConsumerWidget {
  const _Thumb({required this.projectId, required this.photo, required this.size});
  final String projectId;
  final ProjectPhoto photo;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(projectPhotoBytesProvider((projectId: projectId, photoId: photo.id))).valueOrNull;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: SizedBox(
        width: size,
        height: size,
        child: bytes == null
            ? const ColoredBox(color: AppColors.background)
            : Image.memory(
                bytes,
                fit: BoxFit.cover,
                cacheWidth: (size * dpr).ceil(),
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const ColoredBox(
                  color: AppColors.background,
                  child: Icon(Icons.broken_image_outlined, color: AppColors.textMuted),
                ),
              ),
      ),
    );
  }
}

class _ReferenceChoice extends StatelessWidget {
  const _ReferenceChoice({super.key, required this.selected, required this.onTap, required this.child});
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(color: selected ? AppColors.info : AppColors.border, width: selected ? 3 : 1),
        ),
        child: ClipRRect(borderRadius: BorderRadius.circular(AppRadius.control - 1), child: child),
      ),
    );
  }
}
