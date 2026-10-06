import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/config/app_config.dart';
import '../../../core/errors/api_exception.dart' show AccountAccessIssue, ApiException;
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
  void initState() {
    super.initState();
    // Kullanıcı pasif/silinmiş olduğu için oturum az önce ApiClient
    // tarafından düşürüldüyse (bkz. AccountAccessIssue.userBlocked,
    // main.dart onAccountAccessBlocked) -- organizasyon engelinin AKSİNE
    // (bkz. AccountAccessBlockedScreen) bu durum kendi özel ekranını HAK
    // ETMEZ, burada tek seferlik bir bilgi mesajıyla ele alınır. Sebep bir
    // sonraki girişte zaten temizlenir (bkz. AuthController.login), burada
    // AYRICA temizlenir ki ekran yeniden build olduğunda mesaj tekrarlamasın.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showUserBlockedIfNeeded(ref.read(accountAccessIssueProvider));
      ref.read(accountAccessIssueProvider.notifier).state = null;
      _showSessionCheckError(ref.read(authControllerProvider));
    });
  }

  /// Açılışta oturum ağ yüzünden doğrulanamadıysa (ve bilinen kullanıcı da
  /// yoksa) sebebi söyle -- yoksa kullanıcı neden giriş ekranında olduğunu
  /// anlamaz ("Bağlantı kurulamadı..."). Çerezler silinmedi; bağlantı
  /// gelince giriş yapmak yeterli.
  void _showSessionCheckError(AsyncValue<Object?> auth) {
    final error = auth.hasError ? auth.error : null;
    if (_errorMessage == null && error is ApiException) setState(() => _errorMessage = error.message);
  }

  void _showUserBlockedIfNeeded(AccountAccessIssue? issue) {
    if (issue != AccountAccessIssue.userBlocked) return;
    setState(() => _errorMessage = 'Hesabınıza erişiminiz kapatılmıştır. Bilgi için yöneticinizle görüşün.');
  }

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
    // Soğuk açılışta bu ekran /auth/me sonuçlanmadan ÖNCE kurulur (ilk rota
    // /giris); "kullanıcı pasif" sebebi ancak sonra yazılır ve ekran zaten
    // açık olduğu için initState onu hiç görmezdi. Sebep bir sonraki
    // girişte temizlenir (AuthController.login).
    ref.listen<AccountAccessIssue?>(accountAccessIssueProvider, (_, next) => _showUserBlockedIfNeeded(next));
    ref.listen(authControllerProvider, (_, next) => _showSessionCheckError(next));
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
                      semanticsLabel: 'ARVEND Yapı yönetim sistemine giriş ekranı',
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
                    const SizedBox(height: AppSpacing.sm),
                    Center(
                      child: TextButton(
                        onPressed: () => launchUrl(
                          Uri.parse(AppConfig.privacyPolicyUrl),
                          mode: LaunchMode.externalApplication,
                        ),
                        child: const Text('Gizlilik Politikası'),
                      ),
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
    // Web'deki logonun aynısı (frontend/public/logo.png'den
    // scripts/ikon_uret.py ile kırpıldı). Yazı görselin içinde; ekran
    // okuyucu için etiket ayrıca verilir.
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Image.asset(
        'assets/brand/arvend_logo.png',
        width: 160,
        height: 160,
        semanticLabel: 'ARVEND YAPI',
      ),
    );
  }
}
