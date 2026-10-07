import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../../core/errors/api_exception.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_radius.dart';
import '../../../../../core/theme/app_spacing.dart';
import '../../../../../core/theme/app_typography.dart';
import '../../../../../core/widgets/access_notices.dart';
import '../../../../../core/widgets/app_card.dart';
import '../../../../../core/widgets/async_state_view.dart';
import '../../../domain/project_lock_text.dart';
import '../../domain/budget.dart';

// ---------- Metinler (web CostControlSections.tsx ile aynı dil) ----------

/// İzin adları migration 0035'teki `permissions.description` ile aynıdır.
const kBudgetNoAccessText =
    'Proje bütçesini görüntüleme yetkin yok. Yöneticinden rolüne "Proje bütçesini görüntüleme" '
    'iznini eklemesini isteyebilirsin.';

const kCostControlNoAccessText =
    'Maliyet kontrolünü görüntüleme yetkin yok. Yöneticinden rolüne "Maliyet kontrolü (WBS/taahhüt/tahmin) '
    'görüntüleme" iznini eklemesini isteyebilirsin.';

const kBudgetModuleNoAccessText =
    'Bu projenin bütçe ve maliyet bilgilerini görüntüleme yetkin yok. Yöneticinden rolüne "Proje bütçesini '
    'görüntüleme" veya "Maliyet kontrolü (WBS/taahhüt/tahmin) görüntüleme" iznini eklemesini isteyebilirsin.';

const kActualNoAccessText =
    'Gerçekleşen maliyet kırılımı masraf kayıtlarından gelir; görüntülemek için rolünde "Proje finansal '
    'verilerini görüntüleme" izni olmalı.';

const kCostCodesForbiddenText =
    'Maliyet kodu listesini görme yetkin yok. Yöneticinden rolüne "Maliyet kodu kataloğunu görüntüleme" '
    'iznini eklemesini isteyebilirsin.';

/// İzin adları Roller ekranındaki açıklamalarla aynı (migration 0062).
const kBudgetManagePermissionLabel = 'Proje bütçesini oluşturma, baseline alma ve revizyon önerme';
const kBudgetApprovePermissionLabel = 'Bütçe revizyonunu onaylama/reddetme';

/// WBS ve bütçe yazmaları router.go'da `projects.budget.manage` ister.
const kBudgetReadOnlyText =
    'Bütçeyi yalnızca görüntüleyebilirsin; kalem eklemek, baseline almak veya revizyon oluşturmak için rolünde '
    '"$kBudgetManagePermissionLabel" izni olmalı.';

/// Revizyon önerebilen ama karar veremeyen kişiye (ör. Eski Sistem rolü):
/// onay/red düğmelerinin neden olmadığı.
const kBudgetApproveMissingText =
    'Revizyon oluşturabilirsin; onaylamak veya reddetmek için rolünde "$kBudgetApprovePermissionLabel" '
    'izni olmalı.';

/// Kişinin kendi bekleyen revizyonu (Sahip değilse): dört göz ilkesi.
const kBudgetOwnAdjustmentText = 'Bu revizyonu sen oluşturdun; başka bir yetkilinin onaylaması gerekir.';

const kWbsReadOnlyText =
    'WBS ağacını yalnızca görüntüleyebilirsin; düğüm eklemek veya düzenlemek için rolünde '
    '"$kBudgetManagePermissionLabel" izni olmalı.';

const kCostControlReadOnlyText =
    'Maliyet kontrolünü yalnızca görüntüleyebilirsin; taahhüt veya tahmin girmek için rolünde "Maliyet '
    'kontrolünü (WBS/taahhüt/tahmin) yönetme" izni olmalı.';

/// Tüm proje modülleriyle aynı kilit cümlesi (bkz. project_lock_text.dart).
const kProjectLockedText = kProjectLockedNoticeText;

/// Oturum henüz yükleniyor (kullanıcı yok): fail-open izin kontrolü bu
/// anda "her şey açık" sayardı -- izinsiz kişi için istek atılmasın diye
/// ekranlar bu sürede yalnızca yükleniyor gösterir.
bool isAuthPending(AsyncValue<Object?> auth) => auth.isLoading && auth.valueOrNull == null;

/// Backend `requireOpenProject` ile aynı kural (web `locked`).
bool isProjectLocked(String status) => status == 'completed' || status == 'cancelled';

// ---------- Hata yardımcıları ----------

/// 403 sabit bir cümleye çevrilir; diğer hatalarda backend'in Türkçe
/// mesajı (409 durum makinesi mesajları dahil) aynen gösterilir.
String budgetErrorText(Object error) {
  if (error is ApiException) {
    return error.isForbidden ? 'Bu işlem için yetkin yok.' : error.message;
  }
  return 'Beklenmeyen bir hata oluştu.';
}

bool isBudgetForbidden(Object? error) => error is ApiException && error.isForbidden;

/// 409 = kayıt başka biri tarafından değiştirildi (ör. bütçe baseline
/// alındı, revizyon zaten karara bağlandı) -- ekran tazelenmeli.
bool isBudgetConflict(Object? error) => error is ApiException && error.kind == ApiErrorKind.conflict;

// ---------- Diyaloglar ----------

/// Web `useConfirmDialog` karşılığı.
Future<bool> confirmBudgetAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool danger = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Vazgeç')),
        TextButton(
          style: danger ? TextButton.styleFrom(foregroundColor: AppColors.danger) : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Açıklama + zorunlu gerekçe alanlı onay (ör. taahhüt iptali). Vazgeçilirse
/// null; gerekçe boşken onay düğmesi pasiftir.
Future<String?> promptBudgetReason(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String fieldLabel = 'İptal nedeni',
  int maxLength = 300,
  bool danger = true,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _ReasonDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      fieldLabel: fieldLabel,
      maxLength: maxLength,
      danger: danger,
    ),
  );
}

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.fieldLabel,
    required this.maxLength,
    required this.danger,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String fieldLabel;
  final int maxLength;
  final bool danger;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reason = _controller.text.trim();
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.message),
            const SizedBox(height: AppSpacing.md),
            TextField(
              key: const ValueKey('budget-reason-field'),
              controller: _controller,
              autofocus: true,
              minLines: 1,
              maxLines: 3,
              inputFormatters: [LengthLimitingTextInputFormatter(widget.maxLength)],
              decoration: InputDecoration(labelText: '${widget.fieldLabel} *'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Vazgeç')),
        TextButton(
          style: widget.danger ? TextButton.styleFrom(foregroundColor: AppColors.danger) : null,
          onPressed: reason.isEmpty ? null : () => Navigator.of(context).pop(reason),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

// ---------- Görünümler ----------

/// Bilgi kutusu (web'deki gri çerçeveli açıklama paragrafları) -- durum/
/// uyarı değil, bu yüzden nötr.
class BudgetInfoNote extends StatelessWidget {
  const BudgetInfoNote(this.text, {super.key, this.icon = Icons.info_outline, this.title});

  final String text;
  final String? title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: AppColors.textMuted),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  if (title != null)
                    TextSpan(
                      text: '$title ',
                      style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                    ),
                  TextSpan(text: text),
                ],
              ),
              style: AppTypography.helper.copyWith(height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bütçe aşımı vurgusu (varyans < 0) -- durum anlamı taşıdığı için danger.
class OverBudgetBanner extends StatelessWidget {
  const OverBudgetBanner({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, size: 18, color: AppColors.danger),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: AppTypography.helper.copyWith(color: AppColors.danger, fontWeight: FontWeight.w600, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bir ekranın/bölümün yetkisiz durumu -- çökmez, kaydırılabilir kalır.
class BudgetNoAccessView extends StatelessWidget {
  const BudgetNoAccessView({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => NoAccessView(message: message, scrollable: true);
}

/// Ekran içindeki bir bölümün hata durumu: 403 kilitli bilgi kutusu, diğer
/// hatalar "Tekrar Dene"li hata görünümü.
class BudgetSectionError extends StatelessWidget {
  const BudgetSectionError({super.key, required this.error, required this.onRetry, this.forbiddenText});

  final Object error;
  final Future<void> Function() onRetry;
  final String? forbiddenText;

  @override
  Widget build(BuildContext context) {
    if (isBudgetForbidden(error)) {
      return ReadOnlyNotice(forbiddenText ?? 'Bu bölümü görüntüleme yetkin yok.');
    }
    return ErrorState(error: error, onRetry: onRetry);
  }
}

/// Alt ekranlara giden kart (proje detayındaki grup kartlarıyla aynı dil).
class BudgetNavCard extends StatelessWidget {
  const BudgetNavCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: AppColors.gold.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: Icon(icon, color: AppColors.gold, size: 18),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.cardTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                // 2 satır: rozetli kartlarda (ör. "2 bekliyor") alt metin 360 dp'de
                // tek satıra sığmıyordu.
                Text(subtitle, style: AppTypography.metadata, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (badge != null) ...[const SizedBox(width: AppSpacing.sm), badge!],
          const SizedBox(width: AppSpacing.xs),
          const Icon(Icons.chevron_right, color: AppColors.textMuted),
        ],
      ),
    );
  }
}

// ---------- Form alanı ----------

/// Türkçe ondalık virgüllü sayı alanı (bkz. [parseTrDecimal]).
class BudgetNumberField extends StatelessWidget {
  const BudgetNumberField({
    super.key,
    required this.controller,
    required this.label,
    this.required = false,
    this.allowNegative = false,
    this.maxFractionDigits = 2,
    this.enabled = true,
    this.helperText,
    this.hintText,
    this.extraValidator,
    this.onChanged,
    this.fieldKey,
  });

  final TextEditingController controller;
  final String label;
  final bool required;
  final bool allowNegative;
  final int maxFractionDigits;
  final bool enabled;
  final String? helperText;
  final String? hintText;

  /// Ayrıştırılmış değer üzerinde ek kural (ör. sıfır olamaz); null = geçerli.
  final String? Function(double? value)? extraValidator;
  final ValueChanged<String>? onChanged;
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      key: fieldKey,
      controller: controller,
      enabled: enabled,
      onChanged: onChanged,
      keyboardType: TextInputType.numberWithOptions(decimal: true, signed: allowNegative),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(allowNegative ? r'[0-9.,\-−]' : r'[0-9.,]')),
        LengthLimitingTextInputFormatter(22),
      ],
      decoration: InputDecoration(
        labelText: required ? '$label *' : label,
        helperText: helperText,
        helperMaxLines: 3,
        hintText: hintText,
      ),
      validator: (v) {
        if (!enabled) return null;
        final parsed = parseTrDecimal(v ?? '', maxFractionDigits: maxFractionDigits, allowNegative: allowNegative);
        if (parsed.error != null) return parsed.error;
        if (required && parsed.value == null) return '$label zorunludur';
        return extraValidator?.call(parsed.value);
      },
    );
  }
}

// ---------- Biçimleme ----------

final _qtyFormat = NumberFormat.decimalPattern('tr_TR')
  ..minimumFractionDigits = 0
  ..maximumFractionDigits = 4;

/// Miktar gösterimi ("12,5", "1.250") -- en çok 4 ondalık (numeric(14,4)).
String formatBudgetQuantity(double value) => _qtyFormat.format(value);

/// Yüzde, en çok 2 ondalık, Türkçe ("%12,5").
String formatBudgetPercent(double value) {
  final f = NumberFormat.decimalPattern('tr_TR')
    ..minimumFractionDigits = 0
    ..maximumFractionDigits = 2;
  return '%${f.format(value)}';
}

/// Varyansın rengi: aşım danger, bütçe altı success (web ile aynı); tam
/// sıfırda nötr (ne iyi ne kötü).
Color varianceColor(double variance) {
  if (isOverBudget(variance)) return AppColors.danger;
  return variance > 0 ? AppColors.success : AppColors.textMuted;
}

/// EAC'nin revize bütçeye oranı -- YALNIZCA çubuk çizimi içindir, ekranda
/// sayı olarak gösterilmez. Bütçesiz (revize 0) satırda harcama varsa dolu.
double? eacUsagePct(double eac, double revised) {
  if (revised > 0) return eac / revised * 100;
  return eac > 0 ? 100 : null;
}

/// Taahhüt formu ömrü boyunca sabit idempotency anahtarı.
String newIdempotencyKey() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}
