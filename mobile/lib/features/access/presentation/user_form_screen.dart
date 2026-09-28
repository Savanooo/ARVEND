import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../data/access_providers.dart';
import '../domain/access_models.dart';
import 'widgets/access_state_views.dart';

/// Yeni kullanıcı (giriş hesabı) -- web `/admin/kullanicilar/yeni`.
/// Organizasyon rolü BİLİNÇLİ OLARAK boş başlar: en yetkili rol sessizce
/// varsayılan seçilirse forma dokunmadan kaydeden biri istemeden fazladan
/// bir Sahip oluşturabilir. Rol listesi okunur (roles.read), hesap açılır
/// (users.manage) -- biri eksikse form gösterilmez.
class UserFormScreen extends ConsumerStatefulWidget {
  const UserFormScreen({super.key});

  @override
  ConsumerState<UserFormScreen> createState() => _UserFormScreenState();
}

class _UserFormScreenState extends ConsumerState<UserFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  String? _roleCode;
  bool _obscure = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _fullNameController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Rol dahil tüm eksikler aynı anda, alanlarının altında gösterilir.
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    // Kayıt sürerken ekran kapanabilir: liste yine tazelensin.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await container
          .read(accessRepositoryProvider)
          .createUser(
            username: _usernameController.text.trim(),
            password: _passwordController.text,
            fullName: _fullNameController.text.trim(),
            organizationRoleCode: _roleCode!,
          );
      container.invalidate(orgUsersProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kullanıcı oluşturuldu.')));
      context.pop();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authControllerProvider).valueOrNull;
    if (!me.canAccess('organization.users.manage') || !me.canAccess('organization.roles.read')) {
      return const AppPageScaffold(
        title: Text('Yeni Kullanıcı'),
        body: NoAccessView(
          message:
              'Kullanıcı eklemek için rolünde "Kullanıcıları düzenleme" ve "Rolleri görüntüleme" '
              'izinleri olmalı (yalnızca Sahip/Yönetici).',
        ),
      );
    }
    final rolesAsync = ref.watch(organizationRolesProvider);
    return AppPageScaffold(
      title: const Text('Yeni Kullanıcı'),
      body: GuardedAsyncView<List<OrganizationRole>>(
        value: rolesAsync,
        onRetry: () async => ref.invalidate(organizationRolesProvider),
        data: (context, roles) => UnsavedChangesScope(busy: _submitting, child: _form(roles)),
      ),
    );
  }

  Widget _form(List<OrganizationRole> roles) => Form(
    key: _formKey,
    child: ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        AppFormSection(
          title: 'Hesap Bilgileri',
          children: [
            TextFormField(
              controller: _fullNameController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Ad Soyad *'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Ad soyad zorunludur' : null,
            ),
            TextFormField(
              controller: _usernameController,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Kullanıcı Adı *'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Kullanıcı adı zorunludur' : null,
            ),
            TextFormField(
              controller: _passwordController,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Şifre *',
                helperText: 'En az 8 karakter.',
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Şifreyi göster' : 'Şifreyi gizle',
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              validator: (v) => (v == null || v.length < 8) ? 'Şifre en az 8 karakter olmalı' : null,
            ),
          ],
        ),
        AppFormSection(
          title: 'Organizasyon Rolü',
          children: [
            DropdownButtonFormField<String>(
              initialValue: _roleCode,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Rol *'),
              hint: const Text('Rol seçin'),
              validator: (v) => v == null ? 'Rol seçmelisin' : null,
              items: [
                for (final r in roles)
                  DropdownMenuItem(
                    value: r.code,
                    child: Text(r.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() {
                _roleCode = v;
                _error = null;
              }),
            ),
            const Text(
              'Sahip/Yönetici tüm projeleri koşulsuz görür. Proje Yöneticisi/Finans/Saha yalnızca atandıkları '
              'projelere erişir. Kişiye özel yetkileri hesap açıldıktan sonra kullanıcının sayfasından '
              'ayarlayabilirsin.',
              style: AppTypography.helper,
            ),
          ],
        ),
        if (_error != null) ...[Text(_error!, style: AppTypography.error), const SizedBox(height: AppSpacing.md)],
        // Düğme hep etkin: eksikler (rol dahil) basınca alanların
        // altında söylenir -- sebepsiz pasif düğme yanlış sinyal veriyordu.
        PrimaryButton(
          label: 'Kullanıcı Oluştur',
          icon: Icons.person_add_alt_1_outlined,
          loading: _submitting,
          onPressed: _submit,
        ),
      ],
    ),
  );
}
