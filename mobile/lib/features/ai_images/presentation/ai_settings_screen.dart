import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/app_shell.dart' show buildAppBar, kScreenPadding;
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/ai_images_providers.dart';
import '../data/ai_settings_repository.dart';
import '../domain/ai_settings.dart';

/// "Yapay Zekâ Ayarları" (Diğer > Yapay Zekâ Stüdyo'nun altı, Stüdyo'daki
/// dişli): sahibin isteği "bu AI'yi kim kullanacak vb. kural da eklensin,
/// yönetici yapabilsin". Firma anahtarı ve kişi düğmeleri HEMEN kaydedilir
/// (tek dokunuş = tek karar, yanlışlıkla açık kalan "Kaydet"e gerek yok);
/// sınırlar iki sayı birlikte "Kaydet" ile -- yazarken her tuşta istek
/// gitmesin. Her yanıt ayarların tamamıdır; ekran onunla güncellenir.
class AiSettingsScreen extends ConsumerStatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  ConsumerState<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends ConsumerState<AiSettingsScreen> {
  /// Son sunucu yanıtı (ilk yükleme ya da bir değişikliğin yanıtı).
  AiSettings? _settings;
  final _monthly = TextEditingController();
  final _perUser = TextEditingController();
  bool _savingEnabled = false;
  bool _savingLimits = false;
  String? _limitsError;
  final _busyUsers = <String>{};

  @override
  void dispose() {
    _monthly.dispose();
    _perUser.dispose();
    super.dispose();
  }

  void _apply(AiSettings s, {bool resetFields = true}) {
    _settings = s;
    if (resetFields) {
      _monthly.text = s.monthlyLimit?.toString() ?? '';
      _perUser.text = s.perUserMonthlyLimit?.toString() ?? '';
    }
  }

  /// Başarılı her değişiklikten sonra: Stüdyo ve proje sayfaları yeni
  /// kuralı (kapalı / kalan hak) hemen görsün.
  void _changed(AiSettings s, {bool resetFields = false}) {
    ref.invalidate(aiImageStatusProvider);
    if (mounted) setState(() => _apply(s, resetFields: resetFields));
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _setEnabled(bool value) async {
    final s = _settings;
    if (s == null) return;
    setState(() => _savingEnabled = true);
    try {
      // Sınırlar KAYITLI değerleriyle gider: yazılıp kaydedilmemiş sayı
      // anahtarla birlikte sessizce kaydolmasın.
      final next = await ref
          .read(aiSettingsRepositoryProvider)
          .update(enabled: value, monthlyLimit: s.monthlyLimit, perUserMonthlyLimit: s.perUserMonthlyLimit);
      _changed(next);
      _snack(value ? 'Yapay zekâ bu firmada açıldı.' : 'Yapay zekâ bu firmada kapatıldı.');
    } on ApiException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _savingEnabled = false);
    }
  }

  int? _parse(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : int.tryParse(t);
  }

  bool get _limitsDirty {
    final s = _settings;
    if (s == null) return false;
    return _parse(_monthly) != s.monthlyLimit || _parse(_perUser) != s.perUserMonthlyLimit;
  }

  Future<void> _saveLimits() async {
    final s = _settings;
    if (s == null) return;
    final monthly = _parse(_monthly);
    final perUser = _parse(_perUser);
    // Sunucu da reddeder; burada erken söylemek gidiş-dönüşü kurtarır.
    if (monthly != null && s.serverMax > 0 && monthly > s.serverMax) {
      setState(() => _limitsError = 'Aylık firma sınırı en fazla ${s.serverMax} olabilir (sunucu üst sınırı)');
      return;
    }
    setState(() {
      _savingLimits = true;
      _limitsError = null;
    });
    try {
      final next = await ref
          .read(aiSettingsRepositoryProvider)
          .update(enabled: s.enabled, monthlyLimit: monthly, perUserMonthlyLimit: perUser);
      _changed(next, resetFields: true);
      _snack('Sınırlar kaydedildi.');
    } on ApiException catch (e) {
      if (mounted) setState(() => _limitsError = e.message);
    } finally {
      if (mounted) setState(() => _savingLimits = false);
    }
  }

  Future<void> _setUser(AiSettingsUser u, bool? canUse) async {
    setState(() => _busyUsers.add(u.userId));
    try {
      final next = await ref.read(aiSettingsRepositoryProvider).setUser(u.userId, canUse);
      _changed(next);
      if (canUse == null) _snack('${u.fullName}: rolüne bırakıldı.');
    } on ApiException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busyUsers.remove(u.userId));
    }
  }

  Future<void> _refresh() async {
    ref.invalidate(aiSettingsProvider);
    try {
      final s = await ref.read(aiSettingsProvider.future);
      if (mounted) setState(() => _apply(s, resetFields: !_limitsDirty));
    } catch (_) {
      // Hata ekranda gösterilir.
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(aiSettingsProvider);
    // İlk yanıt geldiğinde alanlar doldurulur; sonrakileri değişiklik
    // yanıtları ve aşağı çekip tazeleme getirir.
    if (_settings == null && async.hasValue) _apply(async.requireValue);
    final s = _settings;
    return Scaffold(
      appBar: buildAppBar(kAiSettingsTitle),
      body: s == null
          ? (async.hasError
              ? ErrorState(error: async.error!, onRetry: _refresh)
              : const LoadingState())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: kScreenPadding,
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  _firmCard(s),
                  const SizedBox(height: AppSpacing.lg),
                  const AppSectionHeader(title: 'Kimler kullanabilir'),
                  const SizedBox(height: AppSpacing.xs),
                  _usersCard(s),
                  const SizedBox(height: AppSpacing.lg),
                  const AppSectionHeader(title: 'Sınırlar'),
                  const SizedBox(height: AppSpacing.xs),
                  _limitsCard(s),
                  const SizedBox(height: AppSpacing.lg),
                  const AppSectionHeader(title: 'Bu ay kullanım'),
                  const SizedBox(height: AppSpacing.xs),
                  _usageCard(s),
                  const SizedBox(height: AppSpacing.xl),
                ],
              ),
            ),
    );
  }

  Widget _firmCard(AiSettings s) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
      child: SwitchListTile(
        key: const ValueKey('ai-settings-enabled'),
        contentPadding: EdgeInsets.zero,
        value: s.enabled,
        onChanged: _savingEnabled ? null : _setEnabled,
        title: const Text('Yapay zekâ bu firmada açık', style: AppTypography.body),
        subtitle: Text(
          s.enabled
              ? 'Aşağıda izni olanlar görsel isteyebilir.'
              : 'Kimse yeni görsel isteyemez; hazırlanmış görseller yerinde kalır.',
          style: AppTypography.helper,
        ),
      ),
    );
  }

  Widget _usersCard(AiSettings s) {
    if (s.users.isEmpty) {
      return const AppCard(child: Text('Firmada kullanıcı yok.', style: AppTypography.helper));
    }
    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        children: [
          for (var i = 0; i < s.users.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _UserRow(
              user: s.users[i],
              busy: _busyUsers.contains(s.users[i].userId),
              onChanged: (v) => _setUser(s.users[i], v),
              onFollowRole: () => _setUser(s.users[i], null),
            ),
          ],
        ],
      ),
    );
  }

  Widget _limitsCard(AiSettings s) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('ai-settings-monthly'),
            controller: _monthly,
            enabled: !_savingLimits,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            onChanged: (_) => setState(() => _limitsError = null),
            decoration: InputDecoration(
              labelText: 'Firmanın aylık sınırı (görsel)',
              hintText: '${s.serverMax}',
              helperText: 'Sunucu üst sınırı: ${s.serverMax}. Boş bırakırsan ${s.serverMax}.',
              helperMaxLines: 3,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            key: const ValueKey('ai-settings-per-user'),
            controller: _perUser,
            enabled: !_savingLimits,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            onChanged: (_) => setState(() => _limitsError = null),
            decoration: const InputDecoration(
              labelText: 'Kişi başı aylık sınır (görsel)',
              hintText: 'Sınırsız',
              helperText: 'Boş = sınırsız; yalnızca firmanın sınırı geçerli.',
              helperMaxLines: 3,
            ),
          ),
          if (_limitsError != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(_limitsError!, key: const ValueKey('ai-settings-limits-error'), style: AppTypography.error),
          ],
          const SizedBox(height: AppSpacing.md),
          PrimaryButton(
            key: const ValueKey('ai-settings-save'),
            label: 'Sınırları kaydet',
            loading: _savingLimits,
            onPressed: _savingLimits || !_limitsDirty ? null : _saveLimits,
          ),
        ],
      ),
    );
  }

  Widget _usageCard(AiSettings s) {
    final used = [...s.users.where((u) => u.usedThisMonth > 0)]
      ..sort((a, b) => b.usedThisMonth.compareTo(a.usedThisMonth));
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Firma: ${s.usedThisMonth} / ${s.effectiveMonthlyLimit} görsel',
            key: const ValueKey('ai-settings-usage-total'),
            style: AppTypography.cardTitle,
          ),
          if (s.resetsAt.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text('Yeni hak ${Formatters.date(s.resetsAt)} tarihinde açılır.', style: AppTypography.helper),
          ],
          const SizedBox(height: AppSpacing.sm),
          if (used.isEmpty)
            const Text('Bu ay henüz kimse kullanmadı.', style: AppTypography.helper)
          else
            for (final u in used)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(u.fullName, style: AppTypography.body)),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      s.perUserMonthlyLimit == null
                          ? '${u.usedThisMonth} görsel'
                          : '${u.usedThisMonth} / ${s.perUserMonthlyLimit}',
                      style: AppTypography.metadata,
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({required this.user, required this.busy, required this.onChanged, required this.onFollowRole});

  final AiSettingsUser user;
  final bool busy;
  final ValueChanged<bool> onChanged;
  final VoidCallback onFollowRole;

  @override
  Widget build(BuildContext context) {
    // Sahip her zaman kullanır (sunucu da kapatmayı reddeder): düğme kilitli.
    final custom = !user.isOwner && user.source != AiUseSource.role;
    final label = user.isOwner ? 'Sahip her zaman kullanabilir' : user.source.label;
    return InkWell(
      key: ValueKey('ai-settings-user-${user.userId}'),
      // Kişiye özel ayarı kaldırmanın kısayolu; menü de aynı işi yapar.
      onLongPress: custom && !busy ? onFollowRole : null,
      child: Padding(
        padding: const EdgeInsets.only(left: AppSpacing.lg, top: AppSpacing.sm, bottom: AppSpacing.sm),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(user.fullName, style: AppTypography.body),
                  const SizedBox(height: 2),
                  Text(
                    user.roleName.isEmpty ? label : '${user.roleName} · $label',
                    style: AppTypography.helper.copyWith(
                      color: custom ? AppColors.gold : AppColors.textMuted,
                      fontWeight: custom ? FontWeight.w600 : null,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              key: ValueKey('ai-settings-switch-${user.userId}'),
              value: user.isOwner || user.canUse,
              onChanged: user.isOwner || busy ? null : onChanged,
            ),
            if (custom)
              PopupMenuButton<String>(
                key: ValueKey('ai-settings-menu-${user.userId}'),
                enabled: !busy,
                tooltip: 'Seçenekler',
                onSelected: (_) => onFollowRole(),
                itemBuilder: (_) => const [PopupMenuItem(value: 'role', child: Text('Rolüne bırak'))],
              )
            else
              const SizedBox(width: AppSpacing.lg),
          ],
        ),
      ),
    );
  }
}
