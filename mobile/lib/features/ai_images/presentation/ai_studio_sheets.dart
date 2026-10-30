import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_sheet.dart';
import '../data/ai_images_providers.dart';
import '../data/ai_mask.dart';
import '../data/ai_studio_providers.dart' show aiStudioImageBytesProvider;
import '../domain/ai_image.dart';
import '../domain/ai_studio.dart';
import 'ai_image_sheet.dart' show AiQuotaLine, ensureAiConsent;
import 'ai_mask_editor.dart';

/// Düzenlenecek fotoğraf: telefondan seçilen dosya ya da daha önce
/// üretilmiş bir stüdyo görseli (sonucu yeniden düzenlemek; sunucu
/// kimliğinden okur, yeniden yüklenmez -- source_studio_image_id).
class AiStudioSource {
  const AiStudioSource.file({required String this.path, required String this.name}) : studioImageId = null;
  const AiStudioSource.studio(String this.studioImageId)
      : path = null,
        name = null;

  final String? path;
  final String? name;
  final String? studioImageId;
}

/// "Yeni görsel oluştur": açıklama + örnekler. İş açılınca true döner ve
/// sayfa kapanır; ızgarada "Hazırlanıyor…" kutucuğu görünür.
Future<bool> showAiStudioGenerateSheet(BuildContext context) async {
  final started = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _GenerateSheet(),
  );
  return started ?? false;
}

/// "Fotoğraf yükle ve düzenle"nin ikinci adımı: ne yapılacağını seçtirir.
Future<bool> showAiStudioEditSheet(BuildContext context, {required String path, required String name}) async {
  final started = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _EditSheet(source: AiStudioSource.file(path: path, name: name)),
  );
  return started ?? false;
}

/// Görüntüleyicideki "Düzenle": üretilmiş görsele serbest talimat (kind=edit).
/// Sonuç YENİ bir görsel olur; bu görsel olduğu gibi kalır.
Future<bool> showAiStudioRefineSheet(BuildContext context, String studioImageId) async {
  final started = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _RefineSheet(studioImageId: studioImageId),
  );
  return started ?? false;
}

/// İki sayfanın ortak gönderme mantığı: ilk kullanım bilgisi, iş açma,
/// sunucunun Türkçe hatası (429 kalan hakla gelir).
mixin _StudioSubmit<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool submitting = false;
  String? error;

  Future<void> submit({required String kind, String prompt = '', AiStudioSource? source, AiMask? mask}) async {
    if (!await ensureAiConsent(context, ref) || !mounted) return;
    setState(() {
      submitting = true;
      error = null;
    });
    try {
      await ref.read(aiImageJobsProvider.notifier).startStudio(
            kind: kind,
            prompt: prompt.trim(),
            imagePath: source?.path,
            imageName: source?.name,
            sourceStudioImageId: source?.studioImageId,
            mask: mask?.png,
          );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      // Hak dolduysa satır hemen "doldu"ya dönsün.
      if (e.statusCode == 429) ref.invalidate(aiImageStatusProvider);
      if (mounted) setState(() => error = e.message);
    } on FileSystemException {
      // Seçilen fotoğraf bu arada silindi/okunamadı.
      if (mounted) setState(() => error = 'Fotoğraf okunamadı; yeniden seçin.');
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }
}

class _GenerateSheet extends ConsumerStatefulWidget {
  const _GenerateSheet();

  @override
  ConsumerState<_GenerateSheet> createState() => _GenerateSheetState();
}

class _GenerateSheetState extends ConsumerState<_GenerateSheet> with _StudioSubmit<_GenerateSheet> {
  final _prompt = TextEditingController();

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final quota = ref.watch(aiImageStatusProvider).valueOrNull?.quota;
    final noQuota = quota != null && quota.remaining <= 0;
    return _Frame(
      title: 'Yeni görsel oluştur',
      children: [
        const Text('Nasıl bir görsel istediğini yaz; yapay zekâ sıfırdan hazırlar.', style: AppTypography.helper),
        const SizedBox(height: AppSpacing.sm),
        _PromptField(
          fieldKey: const ValueKey('ai-studio-generate-prompt'),
          controller: _prompt,
          label: 'Nasıl bir görsel?',
          hint: 'ör. Modern salon, ahşap parke',
          onChanged: () => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.sm),
        _Examples(
          examples: kAiGenerateExamples,
          enabled: !submitting,
          onPick: (e) => setState(() => _appendExample(_prompt, e)),
        ),
        const SizedBox(height: AppSpacing.md),
        PrimaryButton(
          icon: Icons.auto_awesome,
          label: 'Görsel oluştur',
          loading: submitting,
          onPressed: submitting || noQuota || _prompt.text.trim().isEmpty
              ? null
              : () => submit(kind: AiImageKind.generate, prompt: _prompt.text),
        ),
        _Footer(error: error),
      ],
    );
  }
}

enum _EditMode { beforeAfter, enhance, custom }

class _EditSheet extends ConsumerStatefulWidget {
  const _EditSheet({required this.source});
  final AiStudioSource source;

  @override
  ConsumerState<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends ConsumerState<_EditSheet> with _StudioSubmit<_EditSheet> {
  final _prompt = TextEditingController();
  _EditMode _mode = _EditMode.beforeAfter;

  /// "Kendin yaz"da isteğe bağlı işaretli alan.
  AiMask? _mask;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  void _select(_EditMode mode) {
    if (mode == _mode) return;
    // Örnekler kipe özgü: "Bitmiş hali" metni "Kendin yaz"a taşınmasın.
    _prompt.clear();
    setState(() {
      _mode = mode;
      _mask = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final quota = ref.watch(aiImageStatusProvider).valueOrNull?.quota;
    final noQuota = quota != null && quota.remaining <= 0;
    final needsPrompt = _mode != _EditMode.enhance;
    final canSend = !submitting && !noQuota && (!needsPrompt || _prompt.text.trim().isNotEmpty);
    final (kind, buttonLabel, buttonIcon) = switch (_mode) {
      _EditMode.beforeAfter => (AiImageKind.beforeAfter, 'Bitmiş halini göster', Icons.auto_awesome),
      _EditMode.enhance => (AiImageKind.enhance, 'Fotoğrafı iyileştir', Icons.tune),
      _EditMode.custom => (AiImageKind.edit, 'Görseli düzenle', Icons.edit_outlined),
    };
    return _Frame(
      title: 'Fotoğrafı düzenle',
      children: [
        Row(
          children: [
            _SourceThumb(source: widget.source, size: 64),
            const SizedBox(width: AppSpacing.md),
            const Expanded(
              child: Text('Bu fotoğraftan yeni bir görsel hazırlanır; fotoğrafın kendisi değişmez.',
                  style: AppTypography.helper),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        _ModeTile(
          key: const ValueKey('ai-studio-mode-before-after'),
          icon: Icons.auto_awesome,
          title: 'Bitmiş halini göster',
          subtitle: 'Aynı oda, aynı açı; iş bitmiş gibi.',
          selected: _mode == _EditMode.beforeAfter,
          onTap: submitting ? null : () => _select(_EditMode.beforeAfter),
        ),
        _ModeTile(
          key: const ValueKey('ai-studio-mode-enhance'),
          icon: Icons.tune,
          title: 'Fotoğrafı iyileştir',
          subtitle: 'Karanlık ya da bulanık fotoğrafı aydınlatır, netleştirir; içerik değişmez.',
          selected: _mode == _EditMode.enhance,
          onTap: submitting ? null : () => _select(_EditMode.enhance),
        ),
        _ModeTile(
          key: const ValueKey('ai-studio-mode-custom'),
          icon: Icons.edit_outlined,
          title: 'Kendin yaz',
          subtitle: 'Ne değişsin, sen yaz.',
          selected: _mode == _EditMode.custom,
          onTap: submitting ? null : () => _select(_EditMode.custom),
        ),
        if (needsPrompt) ...[
          const SizedBox(height: AppSpacing.sm),
          _PromptField(
            fieldKey: const ValueKey('ai-studio-edit-prompt'),
            controller: _prompt,
            label: _mode == _EditMode.beforeAfter ? 'Ne yapılacak?' : 'Ne değişsin?',
            hint: _mode == _EditMode.beforeAfter ? 'ör. Alçıpan asma tavan, spot ışıklı' : 'ör. Duvarı griye boya',
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.sm),
          _Examples(
            // "Bitmiş hali"nde istenen üç örnek; dördüncüsü proje sayfasında.
            examples: _mode == _EditMode.beforeAfter ? kAiBeforeAfterExamples.take(3).toList() : kAiEditExamples,
            enabled: !submitting,
            onPick: (e) => setState(() => _appendExample(_prompt, e)),
          ),
        ],
        if (_mode == _EditMode.custom) ...[
          const SizedBox(height: AppSpacing.sm),
          AiMaskField(
            value: _mask,
            enabled: !submitting,
            onChanged: (m) => setState(() => _mask = m),
            loadSource: () => File(widget.source.path!).readAsBytes(),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        PrimaryButton(
          icon: buttonIcon,
          label: buttonLabel,
          loading: submitting,
          onPressed: canSend
              ? () => submit(
                    kind: kind,
                    prompt: needsPrompt ? _prompt.text : '',
                    source: widget.source,
                    mask: _mode == _EditMode.custom ? _mask : null,
                  )
              : null,
        ),
        _Footer(error: error),
      ],
    );
  }
}

class _RefineSheet extends ConsumerStatefulWidget {
  const _RefineSheet({required this.studioImageId});
  final String studioImageId;

  @override
  ConsumerState<_RefineSheet> createState() => _RefineSheetState();
}

class _RefineSheetState extends ConsumerState<_RefineSheet> with _StudioSubmit<_RefineSheet> {
  final _prompt = TextEditingController();
  AiMask? _mask;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final quota = ref.watch(aiImageStatusProvider).valueOrNull?.quota;
    final noQuota = quota != null && quota.remaining <= 0;
    final source = AiStudioSource.studio(widget.studioImageId);
    return _Frame(
      title: 'Görseli düzenle',
      children: [
        Row(
          children: [
            _SourceThumb(source: source, size: 64),
            const SizedBox(width: AppSpacing.md),
            const Expanded(
              child: Text('Yeni bir görsel hazırlanır; bu görsel olduğu gibi kalır.', style: AppTypography.helper),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _PromptField(
          fieldKey: const ValueKey('ai-studio-refine-prompt'),
          controller: _prompt,
          label: 'Ne değişsin?',
          hint: 'ör. Duvarı griye boya',
          onChanged: () => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.sm),
        _Examples(
          examples: kAiEditExamples,
          enabled: !submitting,
          onPick: (e) => setState(() => _appendExample(_prompt, e)),
        ),
        const SizedBox(height: AppSpacing.sm),
        AiMaskField(
          value: _mask,
          enabled: !submitting,
          onChanged: (m) => setState(() => _mask = m),
          loadSource: () => ref.read(aiStudioImageBytesProvider(widget.studioImageId).future),
        ),
        const SizedBox(height: AppSpacing.md),
        PrimaryButton(
          icon: Icons.edit_outlined,
          label: 'Düzenle',
          loading: submitting,
          onPressed: submitting || noQuota || _prompt.text.trim().isEmpty
              ? null
              : () => submit(kind: AiImageKind.edit, prompt: _prompt.text, source: source, mask: _mask),
        ),
        _Footer(error: error),
      ],
    );
  }
}

/// Örneğe dokununca: alan boşsa örnek yazılır, doluysa virgülle eklenir.
void _appendExample(TextEditingController c, String example) {
  final current = c.text.trim();
  c.text = current.isEmpty ? example : '$current, ${example[0].toLowerCase()}${example.substring(1)}';
  c.selection = TextSelection.collapsed(offset: c.text.length);
}

class _Frame extends StatelessWidget {
  const _Frame({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.viewInsetsOf(context).bottom + AppSpacing.xl,
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

class _PromptField extends StatelessWidget {
  const _PromptField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.hint,
    required this.onChanged,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String hint;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      controller: controller,
      maxLength: kAiPromptMaxLength,
      minLines: 2,
      maxLines: 4,
      textCapitalization: TextCapitalization.sentences,
      onChanged: (_) => onChanged(),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        alignLabelWithHint: true,
        counterText: '',
      ),
    );
  }
}

class _Examples extends StatelessWidget {
  const _Examples({required this.examples, required this.enabled, required this.onPick});
  final List<String> examples;
  final bool enabled;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.xs,
      children: [
        for (final example in examples)
          ActionChip(
            label: Text(example),
            labelStyle: const TextStyle(fontSize: 13),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onPressed: enabled ? () => onPick(example) : null,
          ),
      ],
    );
  }
}

/// Seçilebilir kip satırı. Radyo düğmesi yerine kart: 320 pt'de ve büyük
/// yazıda başlık + açıklama alt alta sarılır, yan yana sıkışmaz.
class _ModeTile extends StatelessWidget {
  const _ModeTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Material(
        color: selected ? AppColors.gold.withValues(alpha: 0.08) : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.control),
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.control),
              border: Border.all(color: selected ? AppColors.gold : AppColors.border, width: selected ? 2 : 1),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: selected ? AppColors.gold : AppColors.textMuted, size: 22),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: AppTypography.cardTitle),
                      const SizedBox(height: 2),
                      Text(subtitle, style: AppTypography.helper),
                    ],
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: AppSpacing.sm),
                  const Icon(Icons.check_circle, color: AppColors.gold, size: 20),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Footer extends ConsumerWidget {
  const _Footer({required this.error});
  final String? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quota = ref.watch(aiImageStatusProvider).valueOrNull?.quota;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) ...[
          const SizedBox(height: AppSpacing.md),
          Text(error!, key: const ValueKey('ai-error'), style: AppTypography.error),
        ],
        if (quota != null) ...[
          const SizedBox(height: AppSpacing.lg),
          AiQuotaLine(quota: quota),
        ],
      ],
    );
  }
}

class _SourceThumb extends ConsumerWidget {
  const _SourceThumb({required this.source, required this.size});
  final AiStudioSource source;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (size * dpr).ceil();
    const placeholder = ColoredBox(color: AppColors.background);
    Widget broken(BuildContext _, Object _, StackTrace? _) => const ColoredBox(
          color: AppColors.background,
          child: Icon(Icons.broken_image_outlined, color: AppColors.textMuted),
        );
    final studioId = source.studioImageId;
    final Widget image;
    if (studioId != null) {
      final bytes = ref.watch(aiStudioImageBytesProvider(studioId)).valueOrNull;
      image = bytes == null
          ? placeholder
          : Image.memory(bytes, fit: BoxFit.cover, cacheWidth: cacheWidth, gaplessPlayback: true, errorBuilder: broken);
    } else {
      image = Image.file(File(source.path!), fit: BoxFit.cover, cacheWidth: cacheWidth, errorBuilder: broken);
    }
    return ClipRRect(
      key: const ValueKey('ai-studio-source'),
      borderRadius: BorderRadius.circular(AppRadius.control),
      child: SizedBox(width: size, height: size, child: image),
    );
  }
}
