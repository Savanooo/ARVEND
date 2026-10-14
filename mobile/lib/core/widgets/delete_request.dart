import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';
import '../utils/formatters.dart';

/// Silme talebi akışının (teklif: backend 0067, proje: 0070) ortak parçaları.

/// Gerekçe/not soran pencereyi açar; vazgeçilirse null, onaylanırsa (boş
/// olabilen) metin. Alanın anahtarı [keyName], onay düğmesininki
/// "[keyName]-confirm".
Future<String?> showNoteDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String label,
  required String confirm,
  required String keyName,
}) => showDialog<String>(
  context: context,
  builder: (context) => NoteDialog(title: title, message: message, label: label, confirm: confirm, keyName: keyName),
);

/// Gerekçe/not soran onay penceresi; denetleyiciyi kendisi tutar (kapanış
/// animasyonu bitmeden atılırsa alan çöküyordu). Vazgeç -> null, onay ->
/// (boş olabilen) metin.
class NoteDialog extends StatefulWidget {
  const NoteDialog({
    super.key,
    required this.title,
    required this.message,
    required this.label,
    required this.confirm,
    required this.keyName,
  });

  final String title;
  final String message;
  final String label;
  final String confirm;
  final String keyName;

  @override
  State<NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<NoteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.message),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: ValueKey(widget.keyName),
              controller: _controller,
              maxLength: 500,
              maxLines: 3,
              minLines: 1,
              decoration: InputDecoration(labelText: widget.label),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Vazgeç')),
        TextButton(
          key: ValueKey('${widget.keyName}-confirm'),
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(widget.confirm),
        ),
      ],
    );
  }
}

/// Bekleyen silme talebi: kim, ne zaman, neden. Silme yetkilisi onaylar ya
/// da reddeder; talebi açan geri çekebilir; diğerleri yalnızca görür.
class DeleteRequestNotice extends StatelessWidget {
  const DeleteRequestNotice({
    super.key,
    required this.subject,
    required this.requestedByName,
    required this.createdAt,
    required this.reason,
    this.onApprove,
    this.onReject,
    this.onWithdraw,
  });

  /// "bu teklifin" / "bu projenin".
  final String subject;
  final String requestedByName;

  /// RFC3339; boş olabilir.
  final String createdAt;
  final String reason;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final VoidCallback? onWithdraw;

  @override
  Widget build(BuildContext context) {
    final who = requestedByName.isEmpty ? 'Bir kullanıcı' : requestedByName;
    final when = createdAt.isEmpty ? '' : ' (${Formatters.dateTime(createdAt)})';
    return Container(
      key: const ValueKey('delete-request-notice'),
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, 10, AppSpacing.md, 10),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.delete_outline, size: 18, color: AppColors.danger),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Silme onayı bekliyor: $who $subject silinmesini istedi$when.'
                  '${reason.isEmpty ? '' : '\nNeden: $reason'}',
                  style: AppTypography.helper.copyWith(color: AppColors.textPrimary, height: 1.35),
                ),
              ),
            ],
          ),
          if (onApprove != null || onReject != null || onWithdraw != null)
            Wrap(
              alignment: WrapAlignment.end,
              spacing: AppSpacing.sm,
              children: [
                if (onWithdraw != null)
                  TextButton(
                    key: const ValueKey('delete-request-withdraw'),
                    onPressed: onWithdraw,
                    child: const Text('Talebi Geri Çek'),
                  ),
                if (onReject != null)
                  TextButton(
                    key: const ValueKey('delete-request-reject'),
                    onPressed: onReject,
                    child: const Text('Reddet'),
                  ),
                if (onApprove != null)
                  TextButton(
                    key: const ValueKey('delete-request-approve'),
                    onPressed: onApprove,
                    style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                    child: const Text('Onayla ve Sil'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
