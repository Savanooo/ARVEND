import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../data/settings_providers.dart';
import '../domain/smtp_settings.dart';

const kPermSettingsRead = 'organization.settings.read';
const kPermSettingsManage = 'organization.settings.manage';

const _noAccessMessage =
    'E-posta (SMTP) ayarları yalnızca Sahip ve Yönetici hesaplarına açık; rolünde "Firma ayarlarını görüntüleme" izni olmalı.';
const _readOnlyMessage =
    'Bu ayarları yalnızca görüntüleyebilirsin; değiştirmek için rolünde "Firma ayarlarını düzenleme" izni olmalı.';

String _errorText(Object error, {bool write = false}) {
  if (error is ApiException) {
    if (error.isForbidden) return write ? 'Bu işlem için yetkin yok.' : _noAccessMessage;
    return error.message;
  }
  return 'Beklenmeyen bir hata oluştu.';
}

/// E-posta (SMTP) ayarları (web `/admin/ayarlar`). Backend'de ek olarak
/// `requireAdmin` olduğundan izin kontrolü KATI `canAccess` ile yapılır
/// (Yönetici'ye kilitli izin -> kaba rol admin de gerekir). Kayıtlı şifre
/// hiçbir zaman gösterilmez; şifre alanı boş bırakılırsa değişmez.
class SmtpSettingsScreen extends ConsumerWidget {
  const SmtpSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    final canRead = user.canAccess(kPermSettingsRead);
    final canManage = canRead && user.canAccess(kPermSettingsManage);

    if (!canRead) {
      return const AppPageScaffold(
        title: Text('E-posta Ayarları'),
        body: NoAccessView(message: _noAccessMessage),
      );
    }

    final settingsAsync = ref.watch(smtpSettingsProvider);
    return AppPageScaffold(
      title: const Text('E-posta Ayarları'),
      body: settingsAsync.when(
        data: (s) => SmtpSettingsForm(settings: s, canManage: canManage),
        loading: () => const LoadingState(),
        error: (err, _) {
          final forbidden = err is ApiException && err.isForbidden;
          return forbidden
              ? NoAccessView(message: _errorText(err))
              : ErrorState(error: err, onRetry: () async => ref.invalidate(smtpSettingsProvider));
        },
      ),
    );
  }
}

/// Ayar formu + test gönderimi. Ekran dışında da (testlerde) kullanılabilir.
class SmtpSettingsForm extends ConsumerStatefulWidget {
  const SmtpSettingsForm({super.key, required this.settings, required this.canManage});

  final SmtpSettings settings;
  final bool canManage;

  @override
  ConsumerState<SmtpSettingsForm> createState() => _SmtpSettingsFormState();
}

class _SmtpSettingsFormState extends ConsumerState<SmtpSettingsForm> {
  final _formKey = GlobalKey<FormState>();
  final _testFormKey = GlobalKey<FormState>();
  late SmtpSettings _saved;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  final _password = TextEditingController();
  late final TextEditingController _fromEmail;
  late final TextEditingController _fromName;
  final _testTo = TextEditingController();
  late bool _useTls;
  bool _obscurePassword = true;
  bool _saving = false;
  bool _testing = false;
  ({String text, bool ok})? _saveMessage;
  ({String text, bool ok})? _testMessage;

  @override
  void initState() {
    super.initState();
    _saved = widget.settings;
    _host = TextEditingController(text: _saved.host);
    _port = TextEditingController(text: '${_saved.portOrDefault}');
    _username = TextEditingController(text: _saved.username);
    _fromEmail = TextEditingController(text: _saved.fromEmail);
    _fromName = TextEditingController(text: _saved.fromName);
    _useTls = _saved.useTls;
    for (final c in [_host, _port, _username, _password, _fromEmail, _fromName]) {
      c.addListener(_onFieldChanged);
    }
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    for (final c in [_host, _port, _username, _password, _fromEmail, _fromName, _testTo]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Kaydedilmemiş değişiklik var mı -- test kayıtlı ayarlarla yapıldığı
  /// için kullanıcı uyarılır.
  bool get _dirty =>
      _host.text.trim() != _saved.host ||
      _port.text.trim() != '${_saved.portOrDefault}' ||
      _username.text.trim() != _saved.username ||
      _password.text.isNotEmpty ||
      _fromEmail.text.trim() != _saved.fromEmail ||
      _fromName.text.trim() != _saved.fromName ||
      _useTls != _saved.useTls;

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _saveMessage = null;
    });
    try {
      final updated = await ref.read(settingsRepositoryProvider).updateSmtp(SmtpSettingsInput(
            host: _host.text,
            port: int.parse(_port.text.trim()),
            username: _username.text,
            password: _password.text,
            fromEmail: _fromEmail.text,
            fromName: _fromName.text,
            useTls: _useTls,
          ));
      if (!mounted) return;
      _password.clear();
      setState(() {
        _saved = updated;
        _saveMessage = (text: 'Kaydedildi.', ok: true);
      });
    } catch (e) {
      if (mounted) setState(() => _saveMessage = (text: _errorText(e, write: true), ok: false));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _sendTest() async {
    if (!_testFormKey.currentState!.validate()) return;
    final to = _testTo.text.trim();
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    try {
      await ref.read(settingsRepositoryProvider).sendTestEmail(to);
      if (mounted) setState(() => _testMessage = (text: 'Test e-postası $to adresine gönderildi.', ok: true));
    } catch (e) {
      if (mounted) setState(() => _testMessage = (text: _errorText(e, write: true), ok: false));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final readOnly = !widget.canManage;
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
      children: [
        _StatusCard(settings: _saved),
        const SizedBox(height: AppSpacing.lg),
        if (readOnly) ...[
          const ReadOnlyNotice(_readOnlyMessage),
          const SizedBox(height: AppSpacing.lg),
        ],
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppFormSection(
                title: 'SMTP Sunucusu',
                children: [
                  TextFormField(
                    controller: _host,
                    enabled: !readOnly,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(labelText: 'Sunucu (Host) *', hintText: 'ör. smtp.gmail.com'),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Sunucu adresi zorunludur' : null,
                  ),
                  TextFormField(
                    controller: _port,
                    enabled: !readOnly,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port *', helperText: 'Genelde 587 (STARTTLS) veya 465'),
                    validator: (v) {
                      final n = int.tryParse((v ?? '').trim());
                      if (n == null || n < 1 || n > 65535) return '1 ile 65535 arasında bir port gir';
                      return null;
                    },
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    value: _useTls,
                    onChanged: readOnly ? null : (v) => setState(() => _useTls = v),
                    title: const Text('TLS/STARTTLS kullan', style: AppTypography.body),
                  ),
                ],
              ),
              AppFormSection(
                title: 'Kimlik Bilgileri',
                children: [
                  TextFormField(
                    controller: _username,
                    enabled: !readOnly,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Kullanıcı Adı'),
                  ),
                  // Kayıtlı şifre asla gösterilmez; salt okunur modda alan
                  // hiç çizilmez (durum kartı "Kayıtlı" bilgisini verir).
                  if (!readOnly)
                    TextFormField(
                      controller: _password,
                      obscureText: _obscurePassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: _saved.passwordSet ? 'Şifre (değiştirmek için doldur)' : 'Şifre',
                        hintText: _saved.passwordSet ? '••••••••' : null,
                        helperText: _saved.passwordSet ? 'Boş bırakırsan kayıtlı şifre değişmez.' : null,
                        suffixIcon: IconButton(
                          tooltip: _obscurePassword ? 'Şifreyi göster' : 'Şifreyi gizle',
                          icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                    ),
                ],
              ),
              AppFormSection(
                title: 'Gönderen',
                children: [
                  TextFormField(
                    controller: _fromEmail,
                    enabled: !readOnly,
                    autocorrect: false,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Gönderen E-posta *'),
                    validator: (v) {
                      final value = (v ?? '').trim();
                      if (value.isEmpty) return 'Gönderen e-posta zorunludur';
                      if (!isValidEmail(value)) return 'Geçerli bir e-posta adresi gir';
                      return null;
                    },
                  ),
                  TextFormField(
                    controller: _fromName,
                    enabled: !readOnly,
                    decoration: const InputDecoration(labelText: 'Gönderen Adı'),
                  ),
                ],
              ),
              if (_saveMessage != null) ...[
                _ResultText(message: _saveMessage!),
                const SizedBox(height: AppSpacing.md),
              ],
              if (!readOnly) PrimaryButton(label: 'Kaydet', loading: _saving, onPressed: _save),
            ],
          ),
        ),
        if (!readOnly) ...[
          const SizedBox(height: AppSpacing.xl),
          const Divider(),
          const SizedBox(height: AppSpacing.lg),
          Form(
            key: _testFormKey,
            child: AppFormSection(
              title: 'Test E-postası Gönder',
              subtitle: 'Test, kayıtlı ayarlarla gönderilir.',
              children: [
                if (_dirty)
                  const _WarningNote('Kaydedilmemiş değişikliklerin var; testten önce kaydet.'),
                TextFormField(
                  controller: _testTo,
                  autocorrect: false,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Alıcı e-posta', hintText: 'ornek@eposta.com'),
                  validator: (v) {
                    final value = (v ?? '').trim();
                    if (value.isEmpty) return 'Test e-postası için bir adres gir.';
                    if (!isValidEmail(value)) return 'Geçerli bir e-posta adresi gir';
                    return null;
                  },
                ),
                if (_testMessage != null) _ResultText(message: _testMessage!),
                SecondaryButton(
                  label: 'Test Et',
                  icon: Icons.send_outlined,
                  loading: _testing,
                  onPressed: _sendTest,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.settings});

  final SmtpSettings settings;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.mail_outline, color: AppColors.gold),
              const SizedBox(width: AppSpacing.sm),
              const Expanded(child: Text('SMTP Durumu', style: AppTypography.sectionTitle)),
              settings.configured
                  ? const StatusBadge(label: 'Yapılandırıldı', tone: StatusTone.success)
                  : const StatusBadge(label: 'Yapılandırılmadı', tone: StatusTone.warning),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          const Text(
            'Teklif ve Ek İş e-postaları bu sunucu üzerinden gönderilir.',
            style: AppTypography.metadata,
          ),
          const SizedBox(height: AppSpacing.xs),
          AppDataRow(label: 'Şifre', value: settings.passwordSet ? 'Kayıtlı' : 'Kayıtlı değil'),
        ],
      ),
    );
  }
}

/// Test bölümündeki "önce kaydet" uyarısı (uyarı tonu).
class _WarningNote extends StatelessWidget {
  const _WarningNote(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    const color = AppColors.warning;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 18, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(message, style: AppTypography.helper.copyWith(color: AppColors.textPrimary))),
        ],
      ),
    );
  }
}

class _ResultText extends StatelessWidget {
  const _ResultText({required this.message});

  final ({String text, bool ok}) message;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          message.ok ? Icons.check_circle_outline : Icons.error_outline,
          size: 18,
          color: message.ok ? AppColors.success : AppColors.danger,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            message.text,
            style: AppTypography.helper.copyWith(color: message.ok ? AppColors.success : AppColors.danger),
          ),
        ),
      ],
    );
  }
}
