import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/status_badge.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/user.dart';
import '../../../core/widgets/app_sheet.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key, this.aboutRoute = '/diger/hakkinda'});

  /// "Hakkında"nın açılacağı rota: Taşeron Paneli kendi yolunu verir
  /// (taşeron hesabı firma kabuğuna giremez).
  final String aboutRoute;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);
    final user = authState.valueOrNull;

    return AppPageScaffold(
      title: const Text('Profil'),
      body: user == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                AppCard(
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 32,
                        backgroundColor: AppColors.navDark,
                        child: Text(
                          _initials(user.fullName),
                          style: const TextStyle(
                            color: AppColors.gold,
                            fontWeight: FontWeight.w800,
                            fontSize: 20,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(user.fullName, style: AppTypography.pageTitle),
                      Text('@${user.username}', style: AppTypography.metadata),
                      const SizedBox(height: AppSpacing.sm),
                      StatusBadge(
                        label: _roleLabel(user),
                        tone: StatusTone.gold,
                      ),
                      if (user.organizationName.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.apartment_outlined,
                              size: 16,
                              color: AppColors.textMuted,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              user.organizationName,
                              style: AppTypography.metadata,
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                AppListCard(
                  title: 'Şifre Değiştir',
                  leading: const Icon(
                    Icons.lock_outline,
                    color: AppColors.gold,
                  ),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: AppColors.textMuted,
                  ),
                  onTap: () => _showChangePasswordSheet(context, ref),
                ),
                AppListCard(
                  title: 'Hakkında',
                  leading: const Icon(
                    Icons.info_outline,
                    color: AppColors.gold,
                  ),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: AppColors.textMuted,
                  ),
                  onTap: () => context.push(aboutRoute),
                ),
                // Hesap silme Süper Admin'de yok: platform hesabı firmaya
                // bağlı değil, uç da firma oturumu ister.
                if (user.role != UserRole.superAdmin)
                  AppListCard(
                    key: const ValueKey('profile-delete-account'),
                    title: 'Hesabımı Sil',
                    leading: const Icon(
                      Icons.person_remove_outlined,
                      color: AppColors.danger,
                    ),
                    trailing: const Icon(
                      Icons.chevron_right,
                      color: AppColors.textMuted,
                    ),
                    onTap: () => _showDeleteAccountSheet(context, ref),
                  ),
                const SizedBox(height: AppSpacing.lg),
                OutlinedButton.icon(
                  icon: const Icon(Icons.logout, color: AppColors.danger),
                  label: const Text(
                    'Çıkış Yap',
                    style: TextStyle(color: AppColors.danger),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.danger),
                  ),
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Çıkış yap'),
                        content: const Text(
                          'Oturumu kapatmak istediğinize emin misiniz?',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: const Text('Vazgeç'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(true),
                            child: const Text('Çıkış Yap'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      await ref.read(authControllerProvider.notifier).logout();
                    }
                  },
                ),
              ],
            ),
    );
  }

  String _initials(String fullName) {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  /// İnce-taneli organizasyon rolü (owner/admin/finance/vb.) varsa o
  /// gösterilir -- daha anlamlı ve doğru bilgi. Yoksa (ör. eski roller
  /// atanmamış) kaba `role` eksenine düşülür.
  String _roleLabel(User user) {
    if (user.organizationRoleName.isNotEmpty) return user.organizationRoleName;
    return switch (user.role) {
      UserRole.admin => 'Yönetici',
      UserRole.kullanici => 'Kullanıcı',
      UserRole.superAdmin => 'Süper Yönetici',
    };
  }

  void _showDeleteAccountSheet(BuildContext context, WidgetRef ref) {
    final messenger = ScaffoldMessenger.of(context);
    showAppSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _DeleteAccountSheet(
        authRepository: ref.read(authRepositoryProvider),
        onDeleted: () async {
          messenger.showSnackBar(const SnackBar(content: Text('Hesabın silindi.')));
          await ref.read(authControllerProvider.notifier).accountDeleted();
        },
      ),
    );
  }

  void _showChangePasswordSheet(BuildContext context, WidgetRef ref) {
    showAppSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _ChangePasswordSheet(
        authRepository: ref.read(authRepositoryProvider),
      ),
    );
  }
}

class _ChangePasswordSheet extends StatefulWidget {
  const _ChangePasswordSheet({required this.authRepository});
  final AuthRepository authRepository;

  @override
  State<_ChangePasswordSheet> createState() => _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends State<_ChangePasswordSheet> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  bool _submitting = false;
  String? _error;
  String? _success;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_newController.text.length < 8) {
      setState(() => _error = 'Yeni şifre en az 8 karakter olmalı');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.authRepository.changePassword(
        currentPassword: _currentController.text,
        newPassword: _newController.text,
      );
      setState(() => _success = 'Şifreniz güncellendi.');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.xl,
        right: AppSpacing.xl,
        top: AppSpacing.xl,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Şifre Değiştir',
            style: AppTypography.pageTitle.copyWith(fontSize: 17),
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _currentController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Mevcut Şifre'),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _newController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Yeni Şifre (en az 8 karakter)',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(_error!, style: AppTypography.error),
          ],
          if (_success != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              _success!,
              style: AppTypography.body.copyWith(
                color: AppColors.success,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          PrimaryButton(
            label: 'Kaydet',
            loading: _submitting,
            onPressed: _submitting ? null : _submit,
          ),
        ],
      ),
    );
  }
}

/// Kendi hesabını silme: ne olacağını açıkça anlatır, şifreyle ve ikinci bir
/// onayla ilerler (geri alınamaz).
class _DeleteAccountSheet extends StatefulWidget {
  const _DeleteAccountSheet({required this.authRepository, required this.onDeleted});
  final AuthRepository authRepository;
  final Future<void> Function() onDeleted;

  @override
  State<_DeleteAccountSheet> createState() => _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends State<_DeleteAccountSheet> {
  final _passwordController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_passwordController.text.isEmpty) {
      setState(() => _error = 'Onaylamak için şifreni gir');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hesabın silinsin mi?'),
        content: const Text('Bu işlem geri alınamaz.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            key: const ValueKey('delete-account-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sil', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.authRepository.deleteOwnAccount(_passwordController.text);
      if (!mounted) return;
      Navigator.of(context).pop();
      await widget.onDeleted();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.xl,
        right: AppSpacing.xl,
        top: AppSpacing.xl,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Hesabımı Sil',
            style: AppTypography.pageTitle.copyWith(fontSize: 17),
          ),
          const SizedBox(height: AppSpacing.md),
          const Text(
            'Hesabın kalıcı olarak silinir: kullanıcı adın, adın ve giriş bilgilerin silinir, '
            'bütün cihazlardaki oturumların kapanır. Bu işlem geri alınamaz.',
            style: AppTypography.body,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Firmanın kayıtları (teklif, proje, masraf vb.) firmada kalır; girdiğin kayıtlarda '
            'adın "Silinmiş kullanıcı" olarak görünür.',
            style: AppTypography.metadata,
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            key: const ValueKey('delete-account-password'),
            controller: _passwordController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Şifren'),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(_error!, style: AppTypography.error),
          ],
          const SizedBox(height: AppSpacing.xl),
          FilledButton(
            key: const ValueKey('delete-account-submit'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Hesabımı Kalıcı Olarak Sil'),
          ),
        ],
      ),
    );
  }
}
