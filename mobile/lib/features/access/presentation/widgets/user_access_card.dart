import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/errors/api_exception.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/unsaved_changes_scope.dart';
import '../../data/access_providers.dart';
import '../../data/access_repository.dart';
import '../../domain/permission_rules.dart';
import 'access_state_views.dart';
import 'permission_matrix.dart';

/// Var olan bir giriş hesabının rolü + kişiye özel detaylı yetkileri --
/// web `UserAccessCard` karşılığı; Personel detayı (bağlı hesap) ve
/// Kullanıcı detayı ortak kullanır. Çağıran `organization.roles.read`
/// iznini kontrol etmiş olmalı; düzenleme [canEdit] (roles.manage) ister.
class UserAccessCard extends ConsumerWidget {
  const UserAccessCard({super.key, required this.userId, required this.canEdit, this.username});

  final String userId;
  final String? username;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bundle = ref.watch(userAccessBundleProvider(userId));
    return bundle.when(
      // Yenilemede (aşağı çekme, kayıt sonrası) eski veri gösterilmeye devam
      // eder; düzenleyici kişiye bağlı kalır, kaydedilmemiş seçimler
      // silinmez (bkz. didUpdateWidget).
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      data: (b) => _UserAccessEditor(
        key: ValueKey('erisim-$userId'),
        userId: userId,
        username: username,
        bundle: b,
        canEdit: canEdit,
      ),
      loading: () => const AppCard(child: SizedBox(height: 96, child: LoadingState())),
      error: (error, _) => AppCard(
        child: error is ApiException && error.isForbidden
            ? const InfoNote(
                'Bu kişinin rol ve yetkilerini görmek için rolünde "Rolleri görüntüleme" izni olmalı.',
                icon: Icons.lock_outline,
              )
            : ErrorState(error: error, onRetry: () async => ref.invalidate(userAccessBundleProvider(userId))),
      ),
    );
  }
}

class _UserAccessEditor extends ConsumerStatefulWidget {
  const _UserAccessEditor({
    super.key,
    required this.userId,
    required this.bundle,
    required this.canEdit,
    this.username,
  });

  final String userId;
  final String? username;
  final UserAccessBundle bundle;
  final bool canEdit;

  @override
  ConsumerState<_UserAccessEditor> createState() => _UserAccessEditorState();
}

class _UserAccessEditorState extends ConsumerState<_UserAccessEditor> {
  late AccessState _saved;
  late AccessState _value;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _saved = _serverState(widget.bundle);
    _value = _saved;
  }

  static AccessState _serverState(UserAccessBundle b) =>
      AccessState(roleCode: b.detail.roleCode, selected: {...b.detail.permissions});

  /// Sunucudan yeni veri geldi (kayıt sonrası ya da aşağı çekip yenileme).
  /// Kaydedilmemiş seçim yoksa düzenleyici yeni duruma geçer; varsa
  /// kişinin seçimi KORUNUR, yalnızca karşılaştırma tabanı (kayıtlı durum)
  /// güncellenir -- yenileme sessizce emek silmesin.
  @override
  void didUpdateWidget(covariant _UserAccessEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.bundle, widget.bundle)) return;
    final server = _serverState(widget.bundle);
    if (_dirty) {
      _saved = server;
    } else {
      _saved = server;
      _value = server;
    }
  }

  bool get _dirty => _value.roleCode != _saved.roleCode || !sameSet(_value.selected, _saved.selected);

  Set<String> _defaultsOf(String roleCode) {
    for (final r in rolesWithCurrent(widget.bundle.roles, widget.bundle.detail)) {
      if (r.code == roleCode) return {...r.permissions};
    }
    return const {};
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    // Kayıt sürerken ekran kapanabilir: önbellekler yine de tazelensin diye
    // kapsayıcı ilk await'ten ÖNCE alınır.
    final container = ProviderScope.containerOf(context, listen: false);
    final userId = widget.userId;
    final target = _value;
    void invalidateAll() {
      container.invalidate(orgUsersProvider);
      container.invalidate(orgUserDetailProvider(userId));
      container.invalidate(userAccessBundleProvider(userId));
    }

    try {
      await saveUserAccess(container.read(accessRepositoryProvider), userId, _saved.roleCode, target);
      invalidateAll();
      if (mounted) {
        setState(() => _saved = target);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Rol ve yetkiler kaydedildi.')));
      }
      // Kişi kendi yetkilerini değiştirdiyse menü/düğmeler hemen uysun.
      final me = container.read(authControllerProvider).valueOrNull;
      if (me?.id == userId) await container.read(authControllerProvider.notifier).refresh();
    } on UserAccessPartialSaveException catch (e) {
      // Rol yazıldı (ve backend kişiye özel ayarları sıfırladı), izinler
      // yazılamadı: kayıtlı durum artık YENİ rolün varsayılanları. Seçim
      // korunur; tekrar Kaydet yalnızca izinleri yazar.
      invalidateAll();
      if (mounted) {
        setState(() {
          _saved = AccessState(roleCode: e.savedRoleCode, selected: _defaultsOf(e.savedRoleCode));
          _error =
              'Rol değiştirildi, ama kişiye özel yetkiler kaydedilemedi (${e.message}). Kişi şu an rolün '
              'varsayılan yetkileriyle çalışıyor; tekrar kaydedebilirsin.';
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.bundle;
    return UnsavedChangesScope(
      dirty: _dirty,
      busy: _busy,
      child: _buildCard(b),
    );
  }

  Widget _buildCard(UserAccessBundle b) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.username != null && widget.username!.isNotEmpty) ...[
            Row(
              children: [
                const Icon(Icons.key_outlined, size: 16, color: AppColors.textMuted),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'Giriş hesabı: ${widget.username}',
                    style: AppTypography.metadata,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          if (!widget.canEdit) ...[
            const ReadOnlyNotice(
              'Yetkileri yalnızca görüntüleyebilirsin; değiştirmek için rolünde '
              '"Rolleri ve izinlerini düzenleme" izni olmalı.',
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          PermissionMatrix(
            roles: rolesWithCurrent(b.roles, b.detail),
            catalog: b.catalog,
            value: _value,
            onChanged: (next) => setState(() => _value = next),
            disabled: _busy,
            readOnly: !widget.canEdit,
          ),
          if (widget.canEdit) ...[
            const SizedBox(height: AppSpacing.md),
            const Divider(),
            const SizedBox(height: AppSpacing.md),
            if (_error != null) ...[Text(_error!, style: AppTypography.error), const SizedBox(height: AppSpacing.sm)],
            PrimaryButton(
              label: 'Rol ve Yetkileri Kaydet',
              loading: _busy,
              onPressed: _dirty && _value.roleCode.isNotEmpty ? _save : null,
            ),
            if (_dirty && !_busy)
              TextButton(
                onPressed: () => setState(() {
                  _value = _saved;
                  _error = null;
                }),
                child: const Text('Değişiklikleri geri al'),
              ),
          ],
        ],
      ),
    );
  }
}
