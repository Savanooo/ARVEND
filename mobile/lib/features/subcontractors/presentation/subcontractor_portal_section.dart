import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_list_card.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/app_sheet.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../../portal/data/portal_repository.dart';
import '../../portal/domain/portal.dart';

const _kUsersRead = 'organization.users.read';
const _kUsersManage = 'organization.users.manage';

/// Geçici şifre: karışan harfler (0/O, 1/l/I) yok, 10 karakter.
String generateTemporaryPassword() {
  const alphabet = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final r = Random.secure();
  return List.generate(10, (_) => alphabet[r.nextInt(alphabet.length)]).join();
}

/// Kullanıcı adı önerisi: adın Türkçe harfleri sadeleştirilmiş, küçük, noktalı.
String suggestPortalUsername(String fullName) {
  const map = {'ç': 'c', 'ğ': 'g', 'ı': 'i', 'ö': 'o', 'ş': 's', 'ü': 'u', 'İ': 'i'};
  // Büyük harf önce küçültülüp eşlenir (Ç -> ç -> c); İ'nin küçüğü noktalı
  // iki karakter olduğu için doğrudan eşlenir.
  final lower = fullName.trim().split('').map((c) => map[c] ?? map[c.toLowerCase()] ?? c.toLowerCase()).join();
  return lower.replaceAll(RegExp(r'[^a-z0-9]+'), '.').replaceAll(RegExp(r'^\.+|\.+$'), '');
}

/// Taşeron kartındaki "Taşeron Paneli" bölümü (backend migration 0075):
/// taşerona giriş açma, şifre sıfırlama, girişi kapatma ve proje izinleri.
/// Görmek organization.users.read, değiştirmek organization.users.manage
/// (Sahip/Yönetici).
class SubcontractorPortalSection extends ConsumerWidget {
  const SubcontractorPortalSection({
    super.key,
    required this.supplierId,
    required this.suggestedName,
    required this.cardActive,
  });

  final String supplierId;

  /// Giriş açma formunda ad soyad önerisi (kartın yetkilisi ya da adı).
  final String suggestedName;
  final bool cardActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    if (!user.canAccess(_kUsersRead)) return const SizedBox.shrink();
    final canManage = user.canAccess(_kUsersManage);
    final async = ref.watch(portalSettingsProvider(supplierId));

    void refresh() => ref.invalidate(portalSettingsProvider(supplierId));

    return Column(
      key: const ValueKey('taseron-paneli'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSectionHeader(title: 'Taşeron Paneli'),
        const Text(
          'Taşeron kendi hesabıyla girer; yalnızca izin verdiğiniz projelerdeki kendi işlerini ve ödemelerini görür.',
          style: AppTypography.helper,
        ),
        const SizedBox(height: AppSpacing.sm),
        async.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text(
            e is ApiException && e.isForbidden ? 'Taşeron girişlerini görmek için yetkin yok.' : 'Taşeron girişleri yüklenemedi.',
            style: AppTypography.error,
          ),
          data: (s) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (s.users.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
                  child: Text('Henüz giriş açılmadı.', style: AppTypography.helper),
                )
              else
                for (final u in s.users)
                  AppListCard(
                    key: ValueKey('portal-kullanici-${u.id}'),
                    leading: Icon(u.isActive ? Icons.person_outline : Icons.person_off_outlined),
                    title: u.fullName,
                    subtitle: [
                      '@${u.username}',
                      if (!u.isActive) 'Giriş kapalı' else if (u.mustChangePassword) 'İlk girişi bekleniyor',
                    ].join(' · '),
                    trailing: canManage
                        ? PopupMenuButton<String>(
                            key: ValueKey('portal-kullanici-menu-${u.id}'),
                            onSelected: (v) async {
                              final changed = v == 'reset'
                                  ? await _resetPassword(context, ref, u)
                                  : await _toggleActive(context, ref, u);
                              if (changed) refresh();
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(value: 'reset', child: Text('Şifreyi sıfırla')),
                              PopupMenuItem(value: 'toggle', child: Text(u.isActive ? 'Girişi kapat' : 'Girişi aç')),
                            ],
                          )
                        : null,
                  ),
              if (canManage && cardActive)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('portal-giris-ac'),
                    icon: const Icon(Icons.person_add_alt_outlined, size: 18),
                    label: const Text('Giriş aç'),
                    onPressed: () async {
                      final created = await showAppSheet<bool>(
                        context: context,
                        isScrollControlled: true,
                        useSafeArea: true,
                        builder: (_) => _CreatePortalUserSheet(supplierId: supplierId, suggestedName: suggestedName),
                      );
                      if (created == true) refresh();
                    },
                  ),
                ),
              const SizedBox(height: AppSpacing.sm),
              Text('Proje izinleri', style: AppTypography.cardTitle),
              const SizedBox(height: 2),
              Text(
                s.granted.isEmpty ? 'Henüz proje izni verilmedi.' : s.granted.map((p) => p.label).join(', '),
                key: const ValueKey('portal-izinler'),
                style: AppTypography.metadata,
              ),
              if (canManage)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('portal-izin-duzenle'),
                    icon: const Icon(Icons.tune, size: 18),
                    label: const Text('İzinleri düzenle'),
                    onPressed: () async {
                      final saved = await showAppSheet<bool>(
                        context: context,
                        isScrollControlled: true,
                        useSafeArea: true,
                        builder: (_) => _PortalProjectsSheet(supplierId: supplierId, settings: s),
                      );
                      if (saved == true) refresh();
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<bool> _resetPassword(BuildContext context, WidgetRef ref, PortalUser u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Şifreyi sıfırla'),
        content: Text('${u.fullName} için yeni bir geçici şifre üretilir; açık oturumları kapanır.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Sıfırla')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return false;
    final password = generateTemporaryPassword();
    try {
      await ref.read(portalRepositoryProvider).resetPassword(supplierId, u.id, password);
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      return false;
    }
    if (context.mounted) await showPortalCredentials(context, username: u.username, password: password);
    return true;
  }

  Future<bool> _toggleActive(BuildContext context, WidgetRef ref, PortalUser u) async {
    final closing = u.isActive;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(closing ? 'Girişi kapat' : 'Girişi aç'),
        content: Text(closing
            ? '${u.fullName} artık Taşeron Paneli\'ne giremez; açık oturumu kapanır.'
            : '${u.fullName} yeniden giriş yapabilir.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(closing ? 'Kapat' : 'Aç')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return false;
    try {
      await ref.read(portalRepositoryProvider).setActive(supplierId, u.id, !closing);
      return true;
    } on ApiException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      return false;
    }
  }
}

/// Giriş bilgilerini gösterir; firma bunları taşerona iletir (kopyala).
Future<void> showPortalCredentials(BuildContext context, {required String username, required String password}) {
  final text = 'ARVEND girişiniz\nKullanıcı adı: $username\nGeçici şifre: $password\n'
      'İlk girişte kendi şifrenizi belirleyeceksiniz.';
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Giriş bilgileri'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Bu bilgileri taşerona iletin. Geçici şifre bir daha gösterilmez.'),
          const SizedBox(height: AppSpacing.md),
          SelectableText('Kullanıcı adı: $username', key: const ValueKey('portal-bilgi-kullanici')),
          SelectableText('Geçici şifre: $password', key: const ValueKey('portal-bilgi-sifre')),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('portal-bilgi-kopyala'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Kopyalandı.')));
            }
          },
          child: const Text('Kopyala'),
        ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Tamam')),
      ],
    ),
  );
}

class _CreatePortalUserSheet extends ConsumerStatefulWidget {
  const _CreatePortalUserSheet({required this.supplierId, required this.suggestedName});
  final String supplierId;
  final String suggestedName;

  @override
  ConsumerState<_CreatePortalUserSheet> createState() => _CreatePortalUserSheetState();
}

class _CreatePortalUserSheetState extends ConsumerState<_CreatePortalUserSheet> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.suggestedName);
  late final _username = TextEditingController(text: suggestPortalUsername(widget.suggestedName));
  final _password = TextEditingController(text: generateTemporaryPassword());
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final u = await ref.read(portalRepositoryProvider).createUser(
            widget.supplierId,
            fullName: _name.text.trim(),
            username: _username.text.trim(),
            temporaryPassword: _password.text,
          );
      if (!mounted) return;
      // Hesap açıldı: düğme bilgiler gösterilirken arkada dönmesin.
      setState(() => _busy = false);
      final nav = Navigator.of(context);
      await showPortalCredentials(context, username: u.username, password: _password.text);
      nav.pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.isForbidden ? 'Giriş açmak için yetkin yok.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return UnsavedChangesScope(
      busy: _busy,
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.xl,
          right: AppSpacing.xl,
          top: AppSpacing.xl,
          bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
        ),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Taşerona giriş aç', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
                const SizedBox(height: AppSpacing.xs),
                const Text(
                  'Taşeron ilk girişte kendi şifresini belirler. Proje izinlerini ayrıca verirsiniz.',
                  style: AppTypography.helper,
                ),
                const SizedBox(height: AppSpacing.lg),
                AppFormSection(
                  title: 'Giriş',
                  children: [
                    TextFormField(
                      key: const ValueKey('portal-ad'),
                      controller: _name,
                      decoration: const InputDecoration(labelText: 'Ad soyad'),
                      validator: (v) => (v ?? '').trim().isEmpty ? 'Ad soyad gerekli' : null,
                    ),
                    TextFormField(
                      key: const ValueKey('portal-kullanici-adi'),
                      controller: _username,
                      autocorrect: false,
                      decoration: const InputDecoration(labelText: 'Kullanıcı adı'),
                      validator: (v) => (v ?? '').trim().isEmpty ? 'Kullanıcı adı gerekli' : null,
                    ),
                    TextFormField(
                      key: const ValueKey('portal-gecici-sifre'),
                      controller: _password,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: 'Geçici şifre',
                        suffixIcon: IconButton(
                          tooltip: 'Yeni şifre üret',
                          icon: const Icon(Icons.refresh),
                          onPressed: () => setState(() => _password.text = generateTemporaryPassword()),
                        ),
                      ),
                      validator: (v) => (v ?? '').length < 8 ? 'En az 8 karakter' : null,
                    ),
                  ],
                ),
                if (_error != null) ...[
                  Text(_error!, style: AppTypography.error),
                  const SizedBox(height: AppSpacing.md),
                ],
                PrimaryButton(
                  key: const ValueKey('portal-giris-kaydet'),
                  label: 'Girişi Aç',
                  loading: _busy,
                  onPressed: _submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PortalProjectsSheet extends ConsumerStatefulWidget {
  const _PortalProjectsSheet({required this.supplierId, required this.settings});
  final String supplierId;
  final PortalSettings settings;

  @override
  ConsumerState<_PortalProjectsSheet> createState() => _PortalProjectsSheetState();
}

class _PortalProjectsSheetState extends ConsumerState<_PortalProjectsSheet> {
  late final Set<String> _selected = {for (final p in widget.settings.projects) if (p.granted) p.id};
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(portalRepositoryProvider).setProjects(widget.supplierId, _selected.toList());
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop(true);
      messenger?.showSnackBar(const SnackBar(content: Text('Proje izinleri kaydedildi.')));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.isForbidden ? 'İzin vermek için yetkin yok.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final projects = widget.settings.projects;
    return UnsavedChangesScope(
      busy: _busy,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Proje izinleri', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
            const SizedBox(height: AppSpacing.xs),
            const Text(
              'Taşeron yalnızca seçtiğiniz projelerdeki kendi işlerini ve ödemelerini görür.',
              style: AppTypography.helper,
            ),
            const SizedBox(height: AppSpacing.md),
            if (projects.isEmpty)
              const Text('Proje yok.', style: AppTypography.helper)
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final p in projects)
                      CheckboxListTile(
                        key: ValueKey('portal-izin-${p.id}'),
                        contentPadding: EdgeInsets.zero,
                        value: _selected.contains(p.id),
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => v == true ? _selected.add(p.id) : _selected.remove(p.id)),
                        title: Text(p.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            if (p.hasEngagement) 'Bu projede işi var',
                            if (p.status == 'cancelled') 'İptal edilmiş proje',
                          ].join(' · '),
                          style: AppTypography.metadata,
                        ),
                      ),
                  ],
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_error!, style: AppTypography.error),
            ],
            const SizedBox(height: AppSpacing.md),
            PrimaryButton(
              key: const ValueKey('portal-izin-kaydet'),
              label: 'Kaydet',
              loading: _busy,
              onPressed: _save,
            ),
          ],
        ),
      ),
    );
  }
}
