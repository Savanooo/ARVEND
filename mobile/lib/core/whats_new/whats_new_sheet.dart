import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_controller.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import '../widgets/app_buttons.dart';
import '../widgets/app_list_card.dart';
import '../widgets/app_sheet.dart';
import 'whats_new.dart';
import 'whats_new_content.dart';

const kWhatsNewTitle = 'Yenilikler';
const kWhatsNewDoneLabel = 'Tamam';

/// "Yenilikler" sayfasını açar. Diğer sayfalar gibi showAppSheet ile: üstte
/// çekme çubuğu, aşağı çekince kapanır; köşede "X" yok, tek düğme "Tamam".
/// Future sayfa kapanınca tamamlanır.
Future<void> showWhatsNewSheet(BuildContext context, WhatsNewNotes notes) {
  return showAppSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => WhatsNewSheet(notes: notes),
  );
}

class WhatsNewSheet extends StatefulWidget {
  const WhatsNewSheet({super.key, required this.notes});

  final WhatsNewNotes notes;

  @override
  State<WhatsNewSheet> createState() => _WhatsNewSheetState();
}

class _WhatsNewSheetState extends State<WhatsNewSheet> {
  /// Uzun listede sayfa ekranın tepesine dayanmaz: arkada uygulamanın bir
  /// şeridi görünür kalır, bunun kapatılabilen bir sayfa olduğu belli olur.
  static const _maxHeightFactor = 0.85;

  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notes = widget.notes;
    return ConstrainedBox(
      key: const Key('whats-new-sheet'),
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * _maxHeightFactor),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.sm),
            child: _Header(version: notes.version),
          ),
          // Küçük telefonda yalnızca maddeler kayar; başlık ve "Tamam" yerinde
          // kalır (düğmeyi bulmak için listenin sonuna inmek gerekmesin).
          // Kaydırma çubuğu hep görünür: liste iki maddenin arasından
          // kesildiğinde aşağıda daha fazlası olduğu başka türlü belli olmuyor.
          // Liste sığıyorsa çubuk da çıkmaz.
          Flexible(
            child: Scrollbar(
              controller: _scroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.md, AppSpacing.xl, AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, item) in notes.items.indexed) ...[
                      if (i > 0) const SizedBox(height: AppSpacing.lg),
                      _ItemRow(item: item),
                    ],
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.lg),
              child: PrimaryButton(label: kWhatsNewDoneLabel, onPressed: () => Navigator.of(context).pop()),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AppColors.navDark,
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          child: const Icon(Icons.auto_awesome_outlined, color: AppColors.gold, size: 24),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(header: true, child: const Text(kWhatsNewTitle, style: AppTypography.pageTitle)),
              const SizedBox(height: 2),
              Text('Sürüm $version', style: AppTypography.metadata),
            ],
          ),
        ),
      ],
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});

  final WhatsNewItem item;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.gold.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.control),
          ),
          child: Icon(item.icon, color: AppColors.gold, size: 22),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title, style: AppTypography.cardTitle.copyWith(fontSize: 15)),
              const SizedBox(height: 2),
              Text(item.body, style: AppTypography.body.copyWith(color: AppColors.textMuted, height: 1.35)),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Yenilikler" satırı (Hakkında ekranı, "Güncellemeleri denetle"nin
/// yanında): en son notları istendiği zaman yeniden açar. Her platformda
/// görünür -- notlar uygulamanın içinde, sunucuya sorulmaz.
class WhatsNewTile extends ConsumerWidget {
  const WhatsNewTile({super.key});

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    // Oturum dokununca okunur, build'de izlenmez: izlemek, oturumun henüz
    // kurulmadığı bir ağaçta yalnızca satırı çizmek için /auth/me isterdi.
    final user = ref.read(authControllerProvider).valueOrNull;
    final notes = await ref.read(whatsNewControllerProvider).latest(user);
    if (notes == null || !context.mounted) return;
    await showWhatsNewSheet(context, notes);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppListCard(
      title: kWhatsNewTitle,
      subtitle: 'Son sürümle gelenler',
      leading: const Icon(Icons.auto_awesome_outlined, color: AppColors.gold),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
      onTap: () => _open(context, ref),
    );
  }
}
