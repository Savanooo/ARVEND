import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_filter_bar.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../../access/presentation/widgets/access_state_views.dart';
import '../data/employees_providers.dart';
import '../domain/employee_record.dart';
import '../employees_paths.dart';

const kEmployeesNoAccessText = 'Personeli görmek için rolünde "Personeli görüntüleme" izni olmalı.';
const kEmployeesReadOnlyText =
    'Personeli yalnızca görüntüleyebilirsin; ekleme, düzenleme ve ücretler için rolünde "Personeli düzenleme" '
    'izni olmalı.';

/// Personel listesi -- web `/admin/personel`. "Personeli görüntüleme"
/// (employees.read) mesai girişi için de verilir: ekleme/düzenleme ve
/// ücretler yalnızca "Personeli düzenleme" (employees.manage) ile.
class EmployeesScreen extends ConsumerStatefulWidget {
  const EmployeesScreen({super.key});

  @override
  ConsumerState<EmployeesScreen> createState() => _EmployeesScreenState();
}

class _EmployeesScreenState extends ConsumerState<EmployeesScreen> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authControllerProvider).valueOrNull;
    if (!me.canAccess('employees.read')) {
      return const AppPageScaffold(
        title: Text('Personel'),
        body: NoAccessView(message: kEmployeesNoAccessText),
      );
    }
    final canManage = me.canAccess('employees.manage');
    final listAsync = ref.watch(employeesListProvider(_filter));
    final filter = _filter;
    Future<void> refresh() =>
        refreshAndWait(ref, [employeesListProvider(filter)], () => ref.read(employeesListProvider(filter).future));

    return AppPageScaffold(
      title: const Text('Personel'),
      floatingActionButton: canManage
          ? FloatingActionButton(
              tooltip: 'Yeni Personel',
              onPressed: () => context.push(EmployeesPaths.create),
              child: const Icon(Icons.person_add_alt_1_outlined),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xs),
            child: AppFilterBar(
              chips: [
                for (final (value, label) in const [('', 'Tümü'), ('aktif', 'Aktif'), ('pasif', 'Pasif')])
                  AppFilterChipData(
                    label: label,
                    selected: _filter == value,
                    onTap: () => setState(() => _filter = value),
                  ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: refresh,
              child: GuardedAsyncView<List<EmployeeRecord>>(
                value: listAsync,
                onRetry: refresh,
                loadingBuilder: (_) => const ListSkeleton(),
                isEmpty: (l) => l.isEmpty,
                emptyBuilder: (_) => const FillScrollable(
                  child: EmptyStateView(message: 'Personel bulunamadı.', icon: Icons.badge_outlined),
                ),
                data: (context, employees) => ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 88),
                  children: [
                    if (!canManage) ...[const ReadOnlyNotice(kEmployeesReadOnlyText), const SizedBox(height: AppSpacing.md)],
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: Text('${employees.length} kişi', style: AppTypography.metadata),
                    ),
                    for (final e in employees)
                      EmployeeListTile(
                        employee: e,
                        showWage: canManage,
                        onTap: () => context.push(EmployeesPaths.detail(e.id)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EmployeeListTile extends StatelessWidget {
  const EmployeeListTile({super.key, required this.employee, required this.showWage, this.onTap});

  final EmployeeRecord employee;

  /// Yalnızca employees.manage -- aksi halde ücret HİÇ çizilmez.
  final bool showWage;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final e = employee;
    // Ücret kendi satırında (kısa biçim, "/ay" - "/gün" kesilmez); görev ve
    // telefon herkes için aynı satırda kalır.
    final wage = showWage ? e.wageShortLabel : null;
    final info = [if (e.position.isNotEmpty) e.position, if (e.phone.isNotEmpty) e.phone].join(' · ');
    return AppCard(
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        children: [
          InitialsAvatar(name: e.fullName, muted: !e.isActive),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(e.fullName, style: AppTypography.cardTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (info.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(info, style: AppTypography.metadata, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
                if (wage != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    wage,
                    style: AppTypography.metadata.copyWith(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (e.hasLogin)
            const Padding(
              padding: EdgeInsets.only(right: AppSpacing.xs),
              child: Tooltip(
                message: 'Giriş hesabı var',
                child: Icon(Icons.key_outlined, size: 16, color: AppColors.textMuted),
              ),
            ),
          StatusRegistry.build(e.isActive ? 'aktif' : 'pasif', StatusRegistry.customer),
        ],
      ),
    );
  }
}
