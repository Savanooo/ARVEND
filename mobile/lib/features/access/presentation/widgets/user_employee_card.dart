import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/errors/api_exception.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_list_card.dart';
import '../../../../core/widgets/app_sheet.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/status_badge.dart';
import '../../../employees/data/employees_providers.dart';
import '../../../employees/domain/employee_record.dart';
import '../../../employees/domain/person_name.dart';
import '../../../employees/employees_paths.dart';
import '../../data/access_providers.dart';
import '../../domain/access_models.dart';
import 'access_state_views.dart';

/// Kullanıcı detayındaki "Personel Kaydı": hesabın bağlı olduğu personel
/// ("kişi = tek kayıt"). Bağlıysa personel sayfasına götürür; değilse neden
/// önemli olduğunu söyler ve (Personeli düzenleme izniyle) kaydı açar ya da
/// mevcut bir personele bağlar -- sahadaki "batu" hesabı / "Batuhan İnci"
/// personeli gibi ayrı kalmış eski kayıtlar buradan tek adımda birleşir.
class UserEmployeeCard extends ConsumerStatefulWidget {
  const UserEmployeeCard({super.key, required this.user});

  final OrgUser user;

  @override
  ConsumerState<UserEmployeeCard> createState() => _UserEmployeeCardState();
}

class _UserEmployeeCardState extends ConsumerState<UserEmployeeCard> {
  bool _busy = false;
  String? _error;

  void _refreshAfter(void Function(ProviderOrFamily) invalidate, String? employeeId) {
    invalidate(orgUserDetailProvider(widget.user.id));
    invalidate(orgUsersProvider);
    invalidateEmployeesWith(invalidate, id: employeeId);
  }

  Future<void> _create() async {
    final u = widget.user;
    setState(() {
      _busy = true;
      _error = null;
    });
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final now = DateTime.now();
      final e = await container
          .read(employeesRepositoryProvider)
          .create(EmployeeInput(fullName: u.fullName, startDate: isoDate(now), userId: u.id));
      _refreshAfter(container.invalidate, e.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${u.fullName} personel kaydı oluşturuldu.')));
      }
    } on ApiException catch (err) {
      if (mounted) setState(() => _error = err.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _link() async {
    final u = widget.user;
    final picked = await showAppSheet<EmployeeRecord>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _UnlinkedEmployeePicker(userFullName: u.fullName),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final container = ProviderScope.containerOf(context, listen: false);
    final repo = container.read(employeesRepositoryProvider);
    try {
      // PUT tam-güncellemedir: kayıt "Personeli düzenleme" ile TAZE okunur
      // (ücretler dolu) ve yalnızca bağ değişerek geri yazılır.
      final fresh = await repo.get(picked.id);
      await repo.update(fresh.id, EmployeeInput.fromRecord(fresh, userId: u.id));
      _refreshAfter(container.invalidate, fresh.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${u.username} hesabı ${fresh.fullName} personeline bağlandı.')));
      }
    } on ApiException catch (err) {
      if (mounted) setState(() => _error = err.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authControllerProvider).valueOrNull;
    final u = widget.user;
    final canRead = me.canAccess('employees.read');
    final canManage = canRead && me.canAccess('employees.manage');
    final employeeId = u.employeeId;

    if (employeeId != null) {
      return AppListCard(
        margin: EdgeInsets.zero,
        leading: const Icon(Icons.badge_outlined, color: AppColors.gold),
        title: u.employeeFullName.isEmpty ? 'Personel kaydı' : u.employeeFullName,
        subtitle: canRead ? 'Personel kaydını aç' : 'Bu hesap bir personel kaydına bağlı.',
        trailing: StatusRegistry.build(u.employeeIsActive ? 'aktif' : 'pasif', StatusRegistry.customer),
        onTap: canRead ? () => context.push(EmployeesPaths.detail(employeeId)) : null,
      );
    }

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const InfoNote(
            'Bu hesabın personel kaydı yok: görev atanamaz, mesai ve maaş listelerinde görünmez.',
            tone: NoteTone.warning,
          ),
          if (canManage) ...[
            const SizedBox(height: AppSpacing.md),
            if (_error != null) ...[Text(_error!, style: AppTypography.error), const SizedBox(height: AppSpacing.sm)],
            PrimaryButton(
              label: 'Personel Kaydı Oluştur',
              icon: Icons.person_add_alt_1_outlined,
              loading: _busy,
              onPressed: _busy ? null : _create,
            ),
            const SizedBox(height: AppSpacing.sm),
            SecondaryButton(label: 'Mevcut Personele Bağla', icon: Icons.link, onPressed: _busy ? null : _link),
          ],
        ],
      ),
    );
  }
}

/// Bağlanabilecek (aktif, hesapsız) personel listesi; kullanıcıyla aynı
/// adı taşıyanlar başta.
class _UnlinkedEmployeePicker extends ConsumerWidget {
  const _UnlinkedEmployeePicker({required this.userFullName});

  final String userFullName;

  String? _subtitle(EmployeeRecord e) {
    final parts = [if (e.position.isNotEmpty) e.position, if (samePersonName(e.fullName, userFullName)) 'Aynı ad'];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(employeesListProvider('aktif'));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Personele Bağla', style: AppTypography.sectionTitle),
            const SizedBox(height: AppSpacing.xs),
            const Text('Yalnızca giriş hesabı olmayan aktif personel listelenir.', style: AppTypography.helper),
            const SizedBox(height: AppSpacing.md),
            Flexible(
              child: AsyncStateView<List<EmployeeRecord>>(
                value: async,
                onRetry: () async => ref.invalidate(employeesListProvider('aktif')),
                data: (context, all) {
                  final unlinked = all.where((e) => !e.hasLogin).toList()
                    ..sort((a, b) {
                      final sa = samePersonName(a.fullName, userFullName) ? 0 : 1;
                      final sb = samePersonName(b.fullName, userFullName) ? 0 : 1;
                      return sa != sb ? sa - sb : a.fullName.compareTo(b.fullName);
                    });
                  if (unlinked.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                      child: Text('Bağlanabilecek personel yok.', style: AppTypography.metadata),
                    );
                  }
                  return ListView(
                    shrinkWrap: true,
                    children: [
                      for (final e in unlinked)
                        AppListCard(
                          leading: InitialsAvatar(name: e.fullName),
                          title: e.fullName,
                          subtitle: _subtitle(e),
                          onTap: () => Navigator.of(context).pop(e),
                        ),
                    ],
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
