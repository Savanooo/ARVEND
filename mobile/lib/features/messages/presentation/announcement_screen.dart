import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../messages_repository.dart';

/// Firma yöneticisinin kendi ekibine duyurusu (POST /announcements):
/// firmadaki her aktif kullanıcıya zil bildirimi + telefona bildirim.
class AnnouncementScreen extends ConsumerStatefulWidget {
  const AnnouncementScreen({super.key});

  static const permission = 'organization.users.manage';

  @override
  ConsumerState<AnnouncementScreen> createState() => _AnnouncementScreenState();
}

class _AnnouncementScreenState extends ConsumerState<AnnouncementScreen> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _body = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Duyuru gönderilsin mi?'),
        content: const Text('Firmadaki bütün aktif kullanıcılara bildirim gidecek. Gönderilen duyuru geri alınamaz.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Gönder')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final n = await ref
          .read(messagesRepositoryProvider)
          .sendAnnouncement(title: _title.text.trim(), body: _body.text.trim());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(n == 0 ? 'Duyuru kaydedildi; gönderilecek başka kullanıcı yok.' : 'Duyuru $n kişiye gönderildi.')),
      );
      context.pop();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    if (!user.canAccess(AnnouncementScreen.permission)) {
      return const AppPageScaffold(
        title: Text('Duyuru Gönder'),
        body: NoAccessView(message: 'Duyuru göndermek için kullanıcı yönetimi yetkisi gerekir.'),
      );
    }
    return AppPageScaffold(
      title: const Text('Duyuru Gönder'),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            AppFormSection(
              title: 'Duyuru',
              subtitle: 'Firmadaki bütün aktif kullanıcılara zil ve telefon bildirimi olarak gider.',
              children: [
                TextFormField(
                  key: const Key('duyuru-baslik'),
                  controller: _title,
                  enabled: !_sending,
                  inputFormatters: [LengthLimitingTextInputFormatter(120)],
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Başlık *', hintText: 'ör. Yarın şantiye kapalı'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Başlık zorunlu' : null,
                ),
                TextFormField(
                  key: const Key('duyuru-metin'),
                  controller: _body,
                  enabled: !_sending,
                  minLines: 3,
                  maxLines: 8,
                  maxLength: 500,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Metin *', alignLabelWithHint: true),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Metin zorunlu' : null,
                ),
              ],
            ),
            if (_error != null) ...[
              Text(_error!, style: AppTypography.error),
              const SizedBox(height: AppSpacing.md),
            ],
            PrimaryButton(
              key: const Key('duyuru-gonder'),
              icon: Icons.campaign_outlined,
              label: 'Gönder',
              loading: _sending,
              onPressed: _send,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Telefonunda bildirim izni kapalı olan kişiler duyuruyu uygulamadaki zil simgesinde görür.',
              style: AppTypography.helper.copyWith(color: AppColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
