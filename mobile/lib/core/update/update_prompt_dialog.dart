import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_status_colors.dart';
import '../theme/app_typography.dart';
import '../utils/formatters.dart';
import '../widgets/app_buttons.dart';
import 'app_release.dart';

enum UpdatePromptChoice { update, later }

/// Bayt -> "62,4 MB" (Android'in kendi dosya boyutu gösterimi gibi 1000
/// tabanlı).
String formatUpdateSize(int bytes) => '${Formatters.decimal(bytes / 1000000)}${kNbsp}MB';

/// RFC3339 -> "28.09.2026" (cihaz saatiyle). DateFormat'ın yerel veri
/// yüklemesine ihtiyaç duymasın diye elle biçimlenir.
String _formatDate(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year}';
}

/// "Yeni sürüm hazır" istemi. Normalde "Sonra" + "Güncelle"; ZORUNLU
/// güncellemede (kurulu build < min_build) yalnızca "Güncelle" vardır,
/// dışına dokunarak ya da geri tuşuyla KAPATILAMAZ.
///
/// Sonucu `Navigator.pop` ile döner: [UpdatePromptChoice] ya da (normal
/// istemde dışarı dokunulup kapatıldıysa) null -- null ERTELEME DEĞİLDİR.
class UpdatePromptDialog extends StatelessWidget {
  const UpdatePromptDialog({
    super.key,
    required this.release,
    required this.installed,
    required this.mandatory,
  });

  final AppRelease release;
  final InstalledVersion? installed;
  final bool mandatory;

  @override
  Widget build(BuildContext context) {
    final facts = <({IconData icon, String label})>[
      (icon: Icons.new_releases_outlined, label: 'Sürüm ${release.displayVersion}'),
      if (release.size > 0) (icon: Icons.download_outlined, label: formatUpdateSize(release.size)),
      if (release.publishedAt != null) (icon: Icons.event_outlined, label: _formatDate(release.publishedAt!)),
    ];

    return PopScope(
      canPop: !mandatory,
      child: UpdateDialogFrame(
        icon: Icons.system_update_outlined,
        title: 'Yeni sürüm hazır',
        subtitle: installed == null ? null : 'Kurulu sürüm: ${installed!.label}',
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [for (final f in facts) _FactChip(icon: f.icon, label: f.label)],
          ),
          if (mandatory) ...[
            const SizedBox(height: AppSpacing.lg),
            const UpdateNotice(
              icon: Icons.error_outline,
              color: AppStatusColors.warning,
              text: 'Bu güncelleme zorunlu. Uygulamayı kullanmaya devam etmek için yeni sürümü yüklemen gerekiyor.',
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          if (release.notes.isNotEmpty) ...[
            const Text('YENİLİKLER', style: AppTypography.overline),
            const SizedBox(height: 6),
            _ReleaseNotes(notes: release.notes),
          ] else
            const Text(
              'Uygulamanın yeni bir sürümü yayınlandı.',
              style: AppTypography.body,
            ),
          const SizedBox(height: AppSpacing.md),
          const Text(
            'Güncelle dediğinde dosya indirilir, güvenlik için doğrulanır ve Android\'in kurulum ekranı açılır.',
            style: AppTypography.helper,
          ),
          const SizedBox(height: AppSpacing.xl),
          // Butonlar tam genişlikte alt alta: 360 dp'lik ekranda yan yana
          // yarım genişlik etiketleri iki satıra kırıyordu.
          PrimaryButton(
            label: 'Güncelle',
            icon: Icons.download_rounded,
            onPressed: () => Navigator.of(context).pop(UpdatePromptChoice.update),
          ),
          if (!mandatory) ...[
            const SizedBox(height: AppSpacing.sm),
            SecondaryButton(
              label: 'Sonra',
              onPressed: () => Navigator.of(context).pop(UpdatePromptChoice.later),
            ),
          ],
        ],
      ),
    );
  }
}

/// Güncelleme diyaloglarının ortak iskeleti: marka rozeti (lacivert zemin +
/// altın ikon, giriş ekranındaki "AY" logosuyla aynı dil) + başlık.
class UpdateDialogFrame extends StatelessWidget {
  const UpdateDialogFrame({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.iconColor = AppColors.gold,
    this.iconBackground = AppColors.navDark,
    required this.children,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color iconColor;
  final Color iconBackground;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: AppSpacing.xl),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card + 4)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: iconBackground,
                      borderRadius: BorderRadius.circular(AppRadius.control + 2),
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, color: iconColor, size: 26),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: AppTypography.pageTitle.copyWith(fontSize: 18)),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(subtitle!, style: AppTypography.metadata),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// Renkli bilgi kutusu (zorunlu güncelleme uyarısı, hata, izin rehberi).
class UpdateNotice extends StatelessWidget {
  const UpdateNotice({super.key, required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(text, style: AppTypography.body.copyWith(fontSize: 13.5, height: 1.4)),
          ),
        ],
      ),
    );
  }
}

class _FactChip extends StatelessWidget {
  const _FactChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.badge + 2),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: AppColors.textMuted),
          const SizedBox(width: 6),
          Text(
            label,
            style: AppTypography.metadata.copyWith(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Uzun sürüm notları diyaloğu ekrandan taşırmasın -- kendi içinde kayar.
class _ReleaseNotes extends StatelessWidget {
  const _ReleaseNotes({required this.notes});

  final String notes;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.border),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Text(notes, style: AppTypography.body.copyWith(fontSize: 13.5, height: 1.45)),
      ),
    );
  }
}
