import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart' show ImageSource;

import '../../../app/app_shell.dart' show buildAppBar, kScreenPadding;
import '../../../core/auth/auth_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/errors/device_errors.dart';
import '../../../core/files/device_picker.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/app_sheet.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../access/domain/permission_rules.dart' show orgRoleIsAdmin;
import '../../projects/domain/project.dart' show exceedsMaxUploadBytes;
import '../data/ai_images_providers.dart';
import '../data/ai_studio_providers.dart';
import '../domain/ai_image.dart';
import '../domain/ai_studio.dart';
import 'ai_badge.dart';
import 'ai_image_sheet.dart' show AiQuotaLine, kAiPreparingText;
import 'ai_studio_sheets.dart';
import 'ai_studio_viewer.dart';

/// "Yapay Zekâ Stüdyo" (Diğer > İş Araçları, Ana Sayfa hızlı işlemi):
/// projeden bağımsız görsel oluşturma ve telefondaki bir fotoğrafı
/// düzenleme -- sahibin isteği "şantiye/proje içinde değil, ayrı bir menü".
/// Altta Görsellerim: en yenisi önce, süren işler "Hazırlanıyor…" kutucuğu,
/// kaydırdıkça devamı. Sahip/Yönetici firmadaki herkesinkini de görür.
class AiStudioScreen extends ConsumerStatefulWidget {
  const AiStudioScreen({super.key});

  @override
  ConsumerState<AiStudioScreen> createState() => _AiStudioScreenState();
}

class _AiStudioScreenState extends ConsumerState<AiStudioScreen> {
  AiStudioScope _scope = AiStudioScope.mine;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    // Kalan hak her açılışta taze okunsun (başka cihazdan da kullanılmış olabilir).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(aiImageStatusProvider);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients || _scroll.position.extentAfter > 600) return;
    ref.read(aiStudioImagesProvider(_scope).notifier).loadMore(auto: true);
  }

  Future<void> _refresh() async {
    ref.invalidate(aiImageStatusProvider);
    ref.invalidate(aiStudioImagesProvider(_scope));
    try {
      await ref.read(aiStudioImagesProvider(_scope).future);
    } catch (_) {
      // Hata ekranda gösterilir.
    }
  }

  Future<void> _pickAndEdit() async {
    final source = await showAppSheet<ImageSource>(
      context: context,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Fotoğraf çek'),
              onTap: () => Navigator.of(context).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Galeriden seç'),
              onTap: () => Navigator.of(context).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    final action = source == ImageSource.camera ? DeviceAction.camera : DeviceAction.gallery;
    final PickedDeviceFile? picked;
    final int size;
    try {
      picked = await ref.read(devicePickerProvider).pickImage(source);
      if (picked == null) return;
      size = picked.size ?? File(picked.path).lengthSync();
    } on Exception catch (e, s) {
      if (mounted) showDeviceIssue(context, ref, e, s, action, where: 'Yapay Zekâ Stüdyo');
      return;
    }
    if (!mounted) return;
    if (exceedsMaxUploadBytes(size, AppConfig.maxUploadBytes)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fotoğraf 25 MiB sınırını aşıyor (${Formatters.fileSize(size)}).')),
      );
      return;
    }
    await showAiStudioEditSheet(context, path: picked.path, name: picked.name);
  }

  void _setScope(AiStudioScope scope) {
    if (scope == _scope) return;
    setState(() => _scope = scope);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    // Firma kapsamı yalnızca Sahip/Yönetici'ye (sunucu da öyle süzer).
    final canSeeFirm = orgRoleIsAdmin(user?.organizationRoleCode ?? '');
    final scope = canSeeFirm ? _scope : AiStudioScope.mine;
    final quota = ref.watch(aiImageStatusProvider).valueOrNull?.quota;
    final listAsync = ref.watch(aiStudioImagesProvider(scope));
    // Sunucuda süren işler (uygulama yeniden açılmış olabilir) izlemeye
    // alınır: bitince liste tazelenir, kökte "Görsel hazır" bandı çıkar.
    ref.listen(aiStudioImagesProvider(scope), (_, next) {
      final pending = next.valueOrNull?.pendingJobs;
      if (pending != null && pending.isNotEmpty) ref.read(aiImageJobsProvider.notifier).trackStudio(pending);
    });
    final tracked = ref.watch(aiImageJobsProvider);
    final list = listAsync.valueOrNull;
    // İzleyicinin bildiği durum sunucu listesinden tazedir: bitmiş iş liste
    // tazelenene kadar "Hazırlanıyor…" görünmesin.
    final pending = <AiImageJob>[
      for (final j in tracked.values)
        if (j.studio && j.isActive) j,
      for (final j in list?.pendingJobs ?? const <AiStudioJob>[])
        if (!tracked.containsKey(j.id) && j.isActive) j.toTracked(),
    ];
    final images = list?.images ?? const <AiStudioImage>[];

    return Scaffold(
      appBar: buildAppBar(kAiStudioTitle),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: kScreenPadding.copyWith(bottom: 0),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  _ActionCard(
                    key: const ValueKey('ai-studio-generate'),
                    icon: Icons.auto_awesome,
                    title: 'Yeni görsel oluştur',
                    subtitle: 'Yazdığın açıklamadan yeni bir görsel hazırlanır.',
                    onTap: () => showAiStudioGenerateSheet(context),
                  ),
                  _ActionCard(
                    key: const ValueKey('ai-studio-upload'),
                    icon: Icons.add_photo_alternate_outlined,
                    title: 'Fotoğraf yükle ve düzenle',
                    subtitle: 'Telefonundaki fotoğrafın bitmiş halini gör, iyileştir ya da istediğin değişikliği yaz.',
                    onTap: _pickAndEdit,
                  ),
                  if (quota != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    AiQuotaLine(quota: quota),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  const AppSectionHeader(title: 'Görsellerim'),
                  if (canSeeFirm) ...[
                    const SizedBox(height: AppSpacing.xs),
                    SegmentedButton<AiStudioScope>(
                      key: const ValueKey('ai-studio-scope'),
                      showSelectedIcon: false,
                      segments: [
                        for (final s in AiStudioScope.values)
                          ButtonSegment(
                            value: s,
                            label: Text(s.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      selected: {scope},
                      onSelectionChanged: (s) => _setScope(s.first),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                ]),
              ),
            ),
            if (list == null && listAsync.hasError)
              SliverToBoxAdapter(
                child: ErrorState(error: listAsync.error!, onRetry: _refresh),
              )
            else if (list == null)
              const SliverToBoxAdapter(
                child: Padding(padding: EdgeInsets.all(AppSpacing.xl), child: Center(child: CircularProgressIndicator())),
              )
            else if (images.isEmpty && pending.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
                  child: EmptyStateView(
                    message: 'Henüz görsel yok. Yukarıdan yeni bir görsel oluştur ya da fotoğraf yükle.',
                    icon: Icons.auto_awesome_outlined,
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                sliver: SliverGrid(
                  // En az 3 sütun (320 pt'de ~90 pt'lik kare), geniş ekranda daha çok.
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 140,
                    mainAxisSpacing: AppSpacing.sm,
                    crossAxisSpacing: AppSpacing.sm,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    childCount: pending.length + images.length,
                    (context, i) {
                      if (i < pending.length) return _PendingTile(job: pending[i]);
                      final index = i - pending.length;
                      final image = images[index];
                      return _ImageTile(
                        key: ValueKey('ai-studio-image-${image.id}'),
                        image: image,
                        onTap: () => showAiStudioViewer(context, images: images, initialIndex: index, scope: scope),
                      );
                    },
                  ),
                ),
              ),
            if (list != null && (list.loadingMore || list.loadMoreError != null))
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Center(
                    child: list.loadingMore
                        ? const CircularProgressIndicator()
                        : TextButton(
                            onPressed: () => ref.read(aiStudioImagesProvider(scope).notifier).loadMore(),
                            child: const Text('Tekrar Dene'),
                          ),
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({super.key, required this.icon, required this.title, required this.subtitle, required this.onTap});

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Alt metin sarılır (AppListCard tek satırda keser): 320 pt'de ve büyük
    // yazıda ne yapacağı okunabilsin.
    return AppCard(
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: AppColors.gold.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: Icon(icon, color: AppColors.gold, size: 20),
          ),
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
          const SizedBox(width: AppSpacing.sm),
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
  }
}

class _PendingTile extends StatelessWidget {
  const _PendingTile({required this.job});
  final AiImageJob job;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('ai-studio-pending-${job.id}'),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(height: AppSpacing.sm),
          // Büyük yazıda kare kutuya sığsın diye küçülerek.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(kAiPreparingText, style: AppTypography.helper.copyWith(fontWeight: FontWeight.w600)),
            ),
          ),
          Flexible(
            child: Text(
              aiKindLabel(job.kind),
              style: AppTypography.helper,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageTile extends ConsumerWidget {
  const _ImageTile({super.key, required this.image, required this.onTap});
  final AiStudioImage image;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytesAsync = ref.watch(aiStudioImageBytesProvider(image.id));
    return LayoutBuilder(
      builder: (context, constraints) {
        final cacheWidth = (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context)).ceil();
        return GestureDetector(
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.control),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  color: AppColors.background,
                  child: bytesAsync.when(
                    data: (bytes) => Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      cacheWidth: cacheWidth,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined, color: AppColors.textMuted),
                    ),
                    loading: () => const SizedBox.shrink(),
                    error: (_, _) => const Icon(Icons.broken_image_outlined, color: AppColors.textMuted),
                  ),
                ),
                if (image.projects.isNotEmpty)
                  const Positioned(
                    right: 4,
                    top: 4,
                    child: Tooltip(
                      message: 'Projeye eklendi',
                      child: CircleAvatar(
                        radius: 11,
                        backgroundColor: AiBadge.color,
                        child: Icon(Icons.folder_outlined, size: 13, color: Colors.white),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
