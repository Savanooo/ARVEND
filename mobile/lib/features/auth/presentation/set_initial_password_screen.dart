import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_providers.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';

/// "İlk giriş" akışı: Super Admin'in provision ettiği bir Owner hesabı,
/// geçici şifreyle giriş yaptıktan sonra bu ekrana yönlendirilir (bkz.
/// app_router.dart redirect zinciri -- user.mustChangePassword=true iken
/// başka hiçbir ekrana erişilemez). Mevcut şifre İSTEMEZ (kullanıcı zaten
/// oturum açmış durumda) -- profil ekranındaki "Şifre Değiştir" akışından
/// (mevcut şifre ister) farkı budur.
class SetInitialPasswordScreen extends ConsumerStatefulWidget {
  const SetInitialPasswordScreen({super.key});

  @override
  ConsumerState<SetInitialPasswordScreen> createState() => _SetInitialPasswordScreenState();
}

class _SetInitialPasswordScreenState extends ConsumerState<SetInitialPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _newPasswordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _obscure = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _newPasswordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_newPasswordController.text != _confirmController.text) {
      setState(() => _error = 'Şifreler eşleşmiyor');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(authRepositoryProvider).setInitialPassword(_newPasswordController.text);
      // Sunucudaki must_change_password bayrağı temizlendi -- oturumdaki
      // User'ı tazele ki router redirect zinciri bu ekrandan çıkabilsin.
      await ref.read(authControllerProvider.notifier).refresh();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_reset_outlined, size: 48, color: AppColors.gold),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      'Yeni Şifre Belirleyin',
                      style: AppTypography.pageTitle,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'İlk girişte, size verilen geçici şifre yerine kendi şifrenizi belirlemeniz gerekiyor.',
                      style: AppTypography.metadata,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.xl + AppSpacing.xs),
                    TextFormField(
                      controller: _newPasswordController,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: 'Yeni Şifre',
                        suffixIcon: IconButton(
                          icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          tooltip: _obscure ? 'Şifreyi göster' : 'Şifreyi gizle',
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      validator: (v) =>
                          (v == null || v.length < 8) ? 'Şifre en az 8 karakter olmalı' : null,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      controller: _confirmController,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: const InputDecoration(labelText: 'Yeni Şifre (Tekrar)'),
                      validator: (v) => (v == null || v.isEmpty) ? 'Şifreyi tekrar girin' : null,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(_error!, style: AppTypography.error, textAlign: TextAlign.center),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                    PrimaryButton(
                      label: 'Devam Et',
                      loading: _submitting,
                      onPressed: _submitting ? null : _submit,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
