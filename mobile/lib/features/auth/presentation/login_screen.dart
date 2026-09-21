import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .login(_usernameController.text.trim(), _passwordController.text);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = e.message);
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
                    const _Wordmark(),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'Yönetim Sistemine Giriş',
                      style: AppTypography.metadata,
                      semanticsLabel: 'ArvenYapı yönetim sistemine giriş ekranı',
                    ),
                    const SizedBox(height: AppSpacing.xxl + AppSpacing.md),
                    TextFormField(
                      controller: _usernameController,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(labelText: 'Kullanıcı Adı'),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Kullanıcı adı gerekli' : null,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.password],
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Şifre',
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          tooltip: _obscurePassword ? 'Şifreyi göster' : 'Şifreyi gizle',
                          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                      validator: (v) => (v == null || v.isEmpty) ? 'Şifre gerekli' : null,
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        _errorMessage!,
                        style: AppTypography.error,
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: AppSpacing.xl),
                    PrimaryButton(
                      label: 'Giriş Yap',
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

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: AppColors.navDark,
            borderRadius: BorderRadius.circular(AppRadius.card),
          ),
          alignment: Alignment.center,
          child: const Text(
            'AY',
            style: TextStyle(
              color: AppColors.gold,
              fontWeight: FontWeight.w800,
              fontSize: 22,
              letterSpacing: 1,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        const Text(
          'ARVEND YAPI',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: 18,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }
}
