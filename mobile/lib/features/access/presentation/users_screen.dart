import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_filter_bar.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../access_paths.dart';
import '../data/access_providers.dart';
import '../domain/access_models.dart';
import '../domain/tr_text.dart';
import 'widgets/access_state_views.dart';

const kUsersNoAccessText =
    'Kullanıcılar yalnızca Sahip veya Yönetici rolündeki, "Kullanıcıları görüntüleme" izni olan kişilere açıktır.';
const kUsersReadOnlyText =
    'Kullanıcıları yalnızca görüntüleyebilirsin; eklemek veya düzenlemek için rolünde "Kullanıcıları düzenleme" '
    'izni olmalı.';

/// Kullanıcılar (giriş hesapları) -- web `/admin/kullanicilar`. Yalnızca
/// kaba rolü admin olan (Sahip/Yönetici) ve `organization.users.read`
/// izni olan kişiye açık (`canAccess` ikisini birden kontrol eder).
/// Backend'de arama/filtre yok; ikisi de çekilmiş tam liste üzerinde.
class UsersScreen extends ConsumerStatefulWidget {
  const UsersScreen({super.key});

  @override
  ConsumerState<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends ConsumerState<UsersScreen> {
  final _searchController = TextEditingController();
  String _query = '';
  String _filter = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matches(OrgUser u) {
    if (_filter == 'aktif' && !u.isActive) return false;
    if (_filter == 'pasif' && u.isActive) return false;
    if (_query.isEmpty) return true;
    final q = searchKey(_query);
    return searchKey(u.fullName).contains(q) || searchKey(u.username).contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authControllerProvider).valueOrNull;
    if (!me.canAccess('organization.users.read')) {
      return const AppPageScaffold(
        title: Text('Kullanıcılar'),
        body: NoAccessView(message: kUsersNoAccessText),
      );
    }
    // Yeni kullanıcı formu rol listesini de çeker (Rolleri görüntüleme).
    final canManage = me.canAccess('organization.users.manage');
    final canCreate = canManage && me.canAccess('organization.roles.read');
    final usersAsync = ref.watch(orgUsersProvider);
    Future<void> refresh() => refreshAndWait(ref, [orgUsersProvider], () => ref.read(orgUsersProvider.future));

    return AppPageScaffold(
      title: const Text('Kullanıcılar'),
      floatingActionButton: canCreate
          ? FloatingActionButton(
              tooltip: 'Yeni Kullanıcı',
              onPressed: () => context.push(AccessPaths.newUser),
              child: const Icon(Icons.person_add_alt_1_outlined),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Ad veya kullanıcı adıyla ara',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xs),
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
              child: GuardedAsyncView<List<OrgUser>>(
                value: usersAsync,
                onRetry: refresh,
                loadingBuilder: (_) => const ListSkeleton(),
                data: (context, users) {
                  final visible = users.where(_matches).toList();
                  if (visible.isEmpty) {
                    return FillScrollable(
                      child: EmptyStateView(
                        message: users.isEmpty ? 'Henüz kullanıcı yok.' : 'Aramana uyan kullanıcı yok.',
                        icon: Icons.people_outline,
                      ),
                    );
                  }
                  final activeCount = users.where((u) => u.isActive).length;
                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 88),
                    children: [
                      if (!canManage) ...[const ReadOnlyNotice(kUsersReadOnlyText), const SizedBox(height: AppSpacing.md)],
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: Text('${users.length} kullanıcı · $activeCount aktif', style: AppTypography.metadata),
                      ),
                      for (final u in visible) UserListTile(user: u, onTap: () => context.push(AccessPaths.user(u.id))),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Kullanıcı satırı -- Personel detayındaki "bağlı giriş hesabı" da aynı
/// görünümü kullanır.
class UserListTile extends StatelessWidget {
  const UserListTile({super.key, required this.user, this.onTap, this.margin});

  final OrgUser user;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    return AppListCard(
      margin: margin ?? const EdgeInsets.only(bottom: AppSpacing.sm),
      leading: InitialsAvatar(name: user.fullName, muted: !user.isActive),
      title: user.fullName,
      subtitle: '${user.username} · ${user.roleLabel}',
      onTap: onTap,
      trailing: user.isActive
          ? const StatusBadge(label: 'Aktif', tone: StatusTone.success)
          : const StatusBadge(label: 'Pasif', tone: StatusTone.danger),
    );
  }
}
