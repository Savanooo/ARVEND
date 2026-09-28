import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../data/dashboard_providers.dart';
import '../../domain/dashboard.dart';

/// Hızlı işlemler için proje seçici (spec §3.5/§6.4). Veri
/// GET /dashboard/project-options'tan gelir -- para alanı taşımaz (D16).
/// Kullanıcının tam 1 açık projesi varsa seçici hiç açılmaz. `onLoading`,
/// seçici açılmadan önceki liste isteği sürerken true alır (çağıran
/// dokunulan butonda gösterge çizer).
Future<ProjectOption?> showProjectPickerSheet(BuildContext context, {void Function(bool loading)? onLoading}) async {
  final repository = ProviderScope.containerOf(context, listen: false).read(dashboardRepositoryProvider);
  List<ProjectOption>? initial;
  onLoading?.call(true);
  try {
    initial = await repository.projectOptions();
  } catch (_) {
    // Seçici kendi hata durumunu gösterir.
  } finally {
    onLoading?.call(false);
  }
  if (initial != null && initial.length == 1) return initial.first;
  if (!context.mounted) return null;
  return showModalBottomSheet<ProjectOption>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ProjectPickerSheet(initial: initial),
  );
}

class ProjectPickerSheet extends ConsumerStatefulWidget {
  const ProjectPickerSheet({super.key, this.initial});

  /// Aramasız ilk liste (seçici açılmadan önce zaten çekildi).
  final List<ProjectOption>? initial;

  @override
  ConsumerState<ProjectPickerSheet> createState() => _ProjectPickerSheetState();
}

class _ProjectPickerSheetState extends ConsumerState<ProjectPickerSheet> {
  String _query = '';
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final useInitial = _query.isEmpty && widget.initial != null;
    final AsyncValue<List<ProjectOption>> options = useInitial
        ? AsyncData(widget.initial!)
        : ref.watch(projectOptionsProvider(_query));
    final height = MediaQuery.sizeOf(context).height * 0.7;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
              child: Text('Proje seç', style: AppTypography.sectionTitle),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: TextField(
                autofocus: false,
                onChanged: _onChanged,
                decoration: const InputDecoration(hintText: 'Proje ara…', prefixIcon: Icon(Icons.search)),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Expanded(
              child: options.when(
                loading: () => const LoadingState(),
                error: (_, _) => const EmptyStateView(message: 'Projeler yüklenemedi.', icon: Icons.error_outline),
                data: (items) => items.isEmpty
                    ? const EmptyStateView(message: 'Açık proje bulunamadı.')
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final p = items[i];
                          return ListTile(
                            title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              [p.projectNo, if (p.customerName.isNotEmpty) p.customerName].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.helper,
                            ),
                            trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
                            onTap: () => Navigator.of(context).pop(p),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
