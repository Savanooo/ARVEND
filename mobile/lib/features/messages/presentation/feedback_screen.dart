import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../messages_repository.dart';

/// Öneri / görüş (POST /feedback): her kullanıcı ARVEND ekibine yazar.
/// Firma yöneticisi görmez -- çalışan firması hakkında da rahat yazsın.
class FeedbackScreen extends ConsumerStatefulWidget {
  const FeedbackScreen({super.key});

  @override
  ConsumerState<FeedbackScreen> createState() => _FeedbackScreenState();
}

const _categories = [
  ('oneri', 'Öneri', Icons.lightbulb_outline),
  ('hata', 'Hata', Icons.bug_report_outlined),
  ('sikayet', 'Şikâyet', Icons.report_outlined),
  ('diger', 'Diğer', Icons.chat_bubble_outline),
];

class _FeedbackScreenState extends ConsumerState<FeedbackScreen> {
  final _formKey = GlobalKey<FormState>();
  final _body = TextEditingController();
  String _category = 'oneri';
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    var version = '';
    try {
      final info = await PackageInfo.fromPlatform();
      version = '${info.version}+${info.buildNumber}';
    } catch (_) {}
    try {
      await ref
          .read(messagesRepositoryProvider)
          .sendFeedback(category: _category, body: _body.text.trim(), appVersion: version);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Teşekkürler, ARVEND ekibine iletildi.')),
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
    return AppPageScaffold(
      title: const Text('Öneri Gönder'),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            Text(
              'Uygulamayla ilgili önerini, karşılaştığın bir hatayı ya da şikâyetini yaz. '
              'Mesajı ARVEND ekibi okur; firma yöneticin görmez.',
              style: AppTypography.body.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppFormSection(
              title: 'Tür',
              children: [
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final (code, label, icon) in _categories)
                      ChoiceChip(
                        key: Key('oneri-tur-$code'),
                        avatar: Icon(icon, size: 18),
                        label: Text(label),
                        selected: _category == code,
                        onSelected: _sending ? null : (_) => setState(() => _category = code),
                      ),
                  ],
                ),
              ],
            ),
            AppFormSection(
              title: 'Mesaj',
              children: [
                TextFormField(
                  key: const Key('oneri-metin'),
                  controller: _body,
                  enabled: !_sending,
                  minLines: 4,
                  maxLines: 10,
                  maxLength: 2000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'Ne oldu, ne olsun istersin?',
                    alignLabelWithHint: true,
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Mesaj boş olamaz' : null,
                ),
              ],
            ),
            if (_error != null) ...[
              Text(_error!, style: AppTypography.error),
              const SizedBox(height: AppSpacing.md),
            ],
            PrimaryButton(
              key: const Key('oneri-gonder'),
              icon: Icons.send_outlined,
              label: 'Gönder',
              loading: _sending,
              onPressed: _send,
            ),
          ],
        ),
      ),
    );
  }
}
