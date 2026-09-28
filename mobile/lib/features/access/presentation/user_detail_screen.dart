import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../data/access_providers.dart';
import '../domain/access_models.dart';
import 'users_screen.dart' show kUsersNoAccessText;
import 'widgets/access_state_views.dart';
import 'widgets/user_access_card.dart';

/// Kullanıcı detayı -- web `/admin/kullanicilar/[id]`: bilgiler (ad soyad +
/// aktiflik), atandığı projeler, şifre sıfırlama (users.manage) ve rol +
/// kişiye özel yetkiler (roles.read görür, roles.manage düzenler).
class UserDetailScreen extends ConsumerWidget {
  const UserDetailScreen({super.key, required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(authControllerProvider).valueOrNull;
    if (!me.canAccess('organization.users.read')) {
      return const AppPageScaffold(
        title: Text('Kullanıcı'),
        body: NoAccessView(message: kUsersNoAccessText),
      );
    }
    final canManage = me.canAccess('organization.users.manage');
    final canReadAccess = me.canAccess('organization.roles.read');
    final canEditAccess = me.canAccess('organization.roles.manage');
    final userAsync = ref.watch(orgUserDetailProvider(userId));

    Future<void> refresh() => refreshAndWait(ref, [
      orgUserDetailProvider(userId),
      userProjectsProvider(userId),
      if (canReadAccess) userAccessBundleProvider(userId),
    ], () => ref.read(orgUserDetailProvider(userId).future));

    return AppPageScaffold(
      title: Text(userAsync.valueOrNull?.fullName ?? 'Kullanıcı'),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: GuardedAsyncView<OrgUser>(
          value: userAsync,
          onRetry: refresh,
          keepDataWhileReloading: true,
          data: (context, u) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
            children: [
              _UserHeader(user: u),
              const SizedBox(height: AppSpacing.xl),
              const AppSectionHeader(title: 'Kullanıcı Bilgileri'),
              const SizedBox(height: AppSpacing.sm),
              // Kişiye bağlı anahtar: yenileme (ör. Rol ve Yetkiler kaydı
              // detayı tazeler) yazılmakta olan adı silmez -- didUpdateWidget.
              _UserInfoCard(key: ValueKey('bilgi-${u.id}'), user: u, canManage: canManage),
              const SizedBox(height: AppSpacing.xl),
              const AppSectionHeader(title: 'Atandığı Projeler'),
              const SizedBox(height: AppSpacing.sm),
              _UserProjectsSection(userId: userId),
              if (canManage) ...[
                const SizedBox(height: AppSpacing.xl),
                const AppSectionHeader(title: 'Şifre Sıfırla'),
                const SizedBox(height: AppSpacing.sm),
                _PasswordResetCard(userId: userId),
              ],
              if (canReadAccess) ...[
                const SizedBox(height: AppSpacing.xl),
                const AppSectionHeader(title: 'Rol ve Yetkiler'),
                const SizedBox(height: AppSpacing.sm),
                UserAccessCard(userId: userId, username: u.username, canEdit: canEditAccess),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _UserHeader extends StatelessWidget {
  const _UserHeader({required this.user});

  final OrgUser user;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        InitialsAvatar(name: user.fullName, size: 52, muted: !user.isActive),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(user.fullName, style: AppTypography.pageTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(user.username, style: AppTypography.metadata, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  StatusBadge(label: user.roleLabel, tone: user.isOwnerOrAdmin ? StatusTone.gold : StatusTone.muted),
                  user.isActive
                      ? const StatusBadge(label: 'Aktif', tone: StatusTone.success)
                      : const StatusBadge(label: 'Pasif', tone: StatusTone.danger),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _UserInfoCard extends ConsumerStatefulWidget {
  const _UserInfoCard({super.key, required this.user, required this.canManage});

  final OrgUser user;
  final bool canManage;

  @override
  ConsumerState<_UserInfoCard> createState() => _UserInfoCardState();
}

class _UserInfoCardState extends ConsumerState<_UserInfoCard> {
  late final TextEditingController _nameController = TextEditingController(text: widget.user.fullName);
  late bool _isActive = widget.user.isActive;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool _dirtyAgainst(OrgUser u) => _nameController.text.trim() != u.fullName || _isActive != u.isActive;

  bool get _dirty => _dirtyAgainst(widget.user);

  /// Sunucudan yeni kullanıcı verisi geldi: form eski kayıtla aynıysa yeni
  /// değerlere geçer; kaydedilmemiş düzenleme varsa KORUNUR.
  @override
  void didUpdateWidget(covariant _UserInfoCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.user, widget.user) || _dirtyAgainst(oldWidget.user)) return;
    _nameController.text = widget.user.fullName;
    _isActive = widget.user.isActive;
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Ad soyad zorunludur.');
      return;
    }
    if (widget.user.isActive && !_isActive) {
      final ok = await confirmAccessAction(
        context,
        title: 'Kullanıcıyı Pasifleştir',
        message: '${widget.user.fullName} artık sisteme giriş yapamayacak. Devam edilsin mi?',
        confirmLabel: 'Pasifleştir',
        danger: true,
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    // Kayıt sürerken ekran kapanabilir: tazeleme yine yapılsın.
    final container = ProviderScope.containerOf(context, listen: false);
    final userId = widget.user.id;
    try {
      await container.read(accessRepositoryProvider).updateUser(userId, fullName: name, isActive: _isActive);
      container.invalidate(orgUsersProvider);
      container.invalidate(orgUserDetailProvider(userId));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kaydedildi.')));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.user;
    if (!widget.canManage) {
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppDataRow(label: 'Ad Soyad', value: u.fullName),
            AppDataRow(label: 'Kullanıcı Adı', value: u.username),
            AppDataRow(label: 'Rol', value: u.roleLabel),
            AppDataRow(
              label: 'Durum',
              value: u.isActive ? 'Aktif' : 'Pasif',
              valueColor: u.isActive ? AppColors.success : AppColors.danger,
            ),
            const SizedBox(height: AppSpacing.sm),
            const ReadOnlyNotice(
              'Bu kullanıcıyı yalnızca görüntüleyebilirsin; düzenlemek için rolünde "Kullanıcıları düzenleme" '
              'izni olmalı.',
            ),
          ],
        ),
      );
    }
    return UnsavedChangesScope(
      dirty: _dirty,
      busy: _saving,
      child: _editCard(),
    );
  }

  Widget _editCard() {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Ad Soyad *'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.xs),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _isActive,
            onChanged: _saving ? null : (v) => setState(() => _isActive = v),
            title: const Text('Aktif', style: AppTypography.body),
            subtitle: const Text('Pasif kullanıcı sisteme giriş yapamaz.', style: AppTypography.helper),
          ),
          if (_error != null) ...[Text(_error!, style: AppTypography.error), const SizedBox(height: AppSpacing.sm)],
          PrimaryButton(label: 'Kaydet', loading: _saving, onPressed: _dirty ? _save : null),
        ],
      ),
    );
  }
}

class _UserProjectsSection extends ConsumerWidget {
  const _UserProjectsSection({required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectsAsync = ref.watch(userProjectsProvider(userId));
    return projectsAsync.when(
      loading: () => const AppCard(child: SizedBox(height: 48, child: LoadingState())),
      error: (e, _) => AppCard(
        child: e is ApiException && e.isForbidden
            ? const InfoNote(kForbiddenMessage, icon: Icons.lock_outline)
            : ErrorState(error: e, onRetry: () async => ref.invalidate(userProjectsProvider(userId))),
      ),
      data: (projects) {
        if (projects.isEmpty) {
          return const AppCard(
            child: Text(
              'Bu kullanıcı açıkça hiçbir projeye atanmamış. (Sahip/Yönetici/eski kullanıcı rolündeyse zaten '
              'tüm projeleri koşulsuz görür.)',
              style: AppTypography.metadata,
            ),
          );
        }
        return Column(
          children: [
            for (final p in projects)
              AppListCard(
                leading: const Icon(Icons.business_outlined, color: AppColors.gold),
                title: p.projectName,
                subtitle: p.projectNo,
                trailing: StatusBadge(label: p.projectRoleLabel, tone: StatusTone.muted),
                onTap: () => context.push('/projeler/${p.projectId}'),
              ),
          ],
        );
      },
    );
  }
}

class _PasswordResetCard extends ConsumerStatefulWidget {
  const _PasswordResetCard({required this.userId});

  final String userId;

  @override
  ConsumerState<_PasswordResetCard> createState() => _PasswordResetCardState();
}

class _PasswordResetCardState extends ConsumerState<_PasswordResetCard> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _saving = false;
  String? _message;
  bool _ok = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _controller.text;
    if (password.length < 8) {
      setState(() {
        _ok = false;
        _message = 'Şifre en az 8 karakter olmalı.';
      });
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await ref.read(accessRepositoryProvider).resetPassword(widget.userId, password);
      if (!mounted) return;
      _controller.clear();
      setState(() {
        _ok = true;
        _message = 'Şifre güncellendi.';
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _ok = false;
          _message = e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Yeni Şifre',
              helperText: 'En az 8 karakter.',
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Şifreyi göster' : 'Şifreyi gizle',
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.md),
          if (_message != null) ...[
            InfoNote(_message!, tone: _ok ? NoteTone.success : NoteTone.danger),
            const SizedBox(height: AppSpacing.md),
          ],
          SecondaryButton(
            label: 'Şifreyi Sıfırla',
            icon: Icons.lock_reset,
            loading: _saving,
            onPressed: _controller.text.isEmpty ? null : _submit,
          ),
        ],
      ),
    );
  }
}
