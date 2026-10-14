import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_sheet.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../suppliers/domain/supplier.dart';
import '../data/subcontractors_repository.dart';
import 'subcontractor_card_form_sheet.dart';

/// Projede "Taşeron Ekle" formundaki seçici: Taşeronlar listesindeki aktif
/// kartlar (arama ile); listede yoksa "Yeni taşeron" kartı açar
/// (organization.suppliers.manage). Seçilen kart döner.
Future<OrganizationSupplier?> showSubcontractorPickerSheet(BuildContext context) {
  return showAppSheet<OrganizationSupplier>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _SubcontractorPickerSheet(),
  );
}

class _SubcontractorPickerSheet extends ConsumerStatefulWidget {
  const _SubcontractorPickerSheet();

  @override
  ConsumerState<_SubcontractorPickerSheet> createState() => _SubcontractorPickerSheetState();
}

class _SubcontractorPickerSheetState extends ConsumerState<_SubcontractorPickerSheet> {
  String _query = '';

  Future<void> _createNew() async {
    final created = await showSubcontractorCardFormSheet(context, initialName: _query);
    if (created != null && mounted) Navigator.of(context).pop(created);
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canCreate = user.canAccess('organization.suppliers.manage');
    final async = ref.watch(subcontractorCardsProvider);
    final height = MediaQuery.sizeOf(context).height * 0.7;
    final q = _query.toLowerCase();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
              child: Text('Taşeron seç', style: AppTypography.sectionTitle),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: TextField(
                key: const ValueKey('taseron-ara'),
                onChanged: (v) => setState(() => _query = v.trim()),
                decoration: const InputDecoration(hintText: 'Taşeron ara…', prefixIcon: Icon(Icons.search)),
              ),
            ),
            if (canCreate)
              ListTile(
                key: const ValueKey('taseron-yeni'),
                leading: const Icon(Icons.person_add_alt_1_outlined, color: AppColors.gold),
                title: Text(_query.isEmpty ? 'Yeni taşeron ekle' : '"$_query" adıyla yeni taşeron'),
                onTap: _createNew,
              ),
            const Divider(height: 1),
            Expanded(
              child: async.when(
                loading: () => const LoadingState(),
                error: (_, _) => const EmptyStateView(message: 'Taşeronlar yüklenemedi.', icon: Icons.error_outline),
                data: (page) {
                  final items = page.cards
                      .where((c) => c.isActive)
                      .where((c) => q.isEmpty || '${c.name} ${c.subtitle}'.toLowerCase().contains(q))
                      .toList();
                  if (items.isEmpty) {
                    return EmptyStateView(
                      message: page.cards.isEmpty ? 'Henüz taşeron yok.' : 'Aramaya uyan taşeron yok.',
                      icon: Icons.engineering_outlined,
                    );
                  }
                  return ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final c = items[i];
                      return ListTile(
                        key: ValueKey('taseron-sec-${c.id}'),
                        title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: c.subtitle.isEmpty
                            ? null
                            : Text(c.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTypography.helper),
                        trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
                        onTap: () => Navigator.of(context).pop(c.supplier),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
