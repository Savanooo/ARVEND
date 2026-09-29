import 'package:flutter/material.dart';

import '../../../../../core/errors/api_exception.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_radius.dart';
import '../../../../../core/theme/app_spacing.dart';
import '../../../../../core/theme/app_typography.dart';
import '../../../../../core/utils/formatters.dart';
import '../../../../../core/widgets/access_notices.dart';
import '../../../domain/project.dart';
import '../../../domain/project_lock_text.dart';
import '../../domain/finance_dates.dart';

/// Ödeme planı / fatura ekranlarının ortak metinleri ve küçük bileşenleri.
/// İzin adları backend izin kataloğundaki (migration 0034) adlarla aynıdır.

const kFinanceNoAccessText =
    'Bu projenin finans bilgilerini görüntüleme yetkin yok. Yöneticinden rolüne "Proje finansal verilerini '
    'görüntüleme" iznini eklemesini ya da seni projeye eklemesini isteyebilirsin.';

const kFinanceManageNoAccessText =
    'Bu işlem için rolünde "Proje finansal işlemlerini yönetme" izni olmalı ve projeye erişimin bulunmalı.';

const kPaymentPlanReadOnlyText =
    'Ödeme planını yalnızca görüntüleyebilirsin; kalem eklemek, düzenlemek veya iptal etmek için rolünde '
    '"Proje finansal işlemlerini yönetme" izni olmalı.';

const kInvoicesReadOnlyText =
    'Faturaları yalnızca görüntüleyebilirsin; fatura eklemek veya durumunu değiştirmek için rolünde '
    '"Proje finansal işlemlerini yönetme" izni olmalı.';

/// Web `locked` ile aynı: tamamlanmış ya da iptal edilmiş projede yeni
/// finans hareketi girilemez (backend `requireOpenProject`, 409).
bool isFinanceLocked(Project project) => project.status == 'completed' || project.status == 'cancelled';

/// Tüm proje modülleriyle aynı kilit cümlesi (bkz. project_lock_text.dart);
/// eskiden her modül ayrı bir metin gösteriyordu.
String financeLockedText(Project project) => kProjectLockedNoticeText;

/// Kilitli proje notu -- ortak [ReadOnlyNotice] görünümü.
class FinanceLockedNotice extends StatelessWidget {
  const FinanceLockedNotice({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) => ReadOnlyNotice(financeLockedText(project));
}

/// Yazma işlemlerinde gösterilecek metin: 403 sabit bir cümleye, 404 (kayıt
/// bu arada iptal edilmiş/silinmiş; backend bu durumda yanıltıcı biçimde
/// "proje bulunamadı" der) kendi cümlemize çevrilir; diğerlerinde (409 dahil)
/// backend'in Türkçe mesajı gösterilir.
String financePlanErrorText(Object error) {
  if (error is ApiException) {
    if (error.isForbidden) return 'Bu işlem için yetkin yok.';
    if (error.kind == ApiErrorKind.notFound) {
      return 'Kayıt bulunamadı; bu arada değiştirilmiş veya iptal edilmiş olabilir. Liste yenilendi.';
    }
    return error.message;
  }
  return 'Beklenmeyen bir hata oluştu.';
}

bool isFinanceForbidden(Object? error) => error is ApiException && error.isForbidden;

bool isFinanceConflict(Object? error) => error is ApiException && error.kind == ApiErrorKind.conflict;

bool isFinanceNotFound(Object? error) => error is ApiException && error.kind == ApiErrorKind.notFound;

/// Onay penceresi -- iptal gibi yıkıcı aksiyonlarda onay düğmesi kırmızı.
Future<bool> confirmFinanceAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool danger = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Vazgeç')),
        TextButton(
          style: danger ? TextButton.styleFrom(foregroundColor: AppColors.danger) : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// İsteğe bağlı tarih alanı (boş bırakılabilir, temizlenebilir) -- proje
/// düzenleme formundaki tarih alanıyla aynı görünüm.
class FinanceDateField extends StatelessWidget {
  const FinanceDateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.clearable = true,
    this.helperText,
    this.errorText,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool clearable;
  final String? helperText;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final v = value;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: v ?? DateTime.now(),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (picked != null) onChanged(DateTime.utc(picked.year, picked.month, picked.day));
      },
      child: InputDecorator(
        isEmpty: v == null,
        decoration: InputDecoration(
          labelText: label,
          helperText: helperText,
          helperMaxLines: 2,
          errorText: errorText,
          suffixIcon: v != null && clearable
              ? IconButton(
                  tooltip: 'Tarihi temizle',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => onChanged(null),
                )
              : const Icon(Icons.calendar_today_outlined, size: 18),
        ),
        child: v == null ? null : Text(Formatters.date(apiDate(v)), style: AppTypography.body),
      ),
    );
  }
}

/// Vade ipucu metni ("3 gün gecikti" kırmızı, "Bugün vadeli"/"5 gün kaldı"
/// turuncu) -- [dueHint] sonucunu çizer.
class DueHintText extends StatelessWidget {
  const DueHintText({super.key, required this.hint, this.style});

  final ({String text, DueTone tone}) hint;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final color = hint.tone == DueTone.overdue ? AppColors.danger : AppColors.warning;
    return Text(
      hint.text,
      style: (style ?? AppTypography.metadata).copyWith(color: color, fontWeight: FontWeight.w700),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Uyarı şeridi (gecikmiş kalem/fatura sayısı gibi) -- kırmızı zemin, ikon +
/// metin. Durum rengi taşır (danger), marka rengi (gold) DEĞİL.
class FinanceAlertStrip extends StatelessWidget {
  const FinanceAlertStrip({super.key, required this.text, this.detail});

  final String text;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.danger),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: AppTypography.body.copyWith(color: AppColors.danger, fontWeight: FontWeight.w700)),
                if (detail != null) ...[
                  const SizedBox(height: 2),
                  Text(detail!, style: AppTypography.helper.copyWith(height: 1.35)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// RefreshIndicator altında ortalanmış içerik (hata/boş durum) -- aşağı
/// çekme çalışsın diye kaydırılabilir.
class FinanceScrollableCenter extends StatelessWidget {
  const FinanceScrollableCenter({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight.isFinite ? constraints.maxHeight : 0),
          child: Center(child: child),
        ),
      ),
    );
  }
}
