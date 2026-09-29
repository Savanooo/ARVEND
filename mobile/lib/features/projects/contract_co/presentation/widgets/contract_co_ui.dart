import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../../core/errors/api_exception.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_radius.dart';
import '../../../../../core/theme/app_spacing.dart';
import '../../../../../core/theme/app_typography.dart';
import '../../../../../core/utils/formatters.dart';
import '../../../../../core/widgets/access_notices.dart';
import '../../../../../core/widgets/app_card.dart';
import '../../../../../core/widgets/app_data_row.dart';
import '../../../../auth/domain/user.dart';
import '../../../domain/project.dart';
import '../../../domain/project_lock_text.dart';

/// Sözleşme + Ek İşler ekranlarının ortak metinleri ve küçük parçaları.
/// İzin adları web/Roller ekranındaki açıklamalarla aynı (migration 0034/
/// 0036 `permissions.description`), düz çift tırnakla.

const kContractNoAccessText =
    'Proje sözleşmesini görüntüleme yetkin yok. Yöneticinden rolüne "Proje sözleşmesini görüntüleme" '
    'iznini eklemesini isteyebilirsin.';

const kContractReadOnlyText =
    'Sözleşmeyi yalnızca görüntüleyebilirsin; taslağı düzenlemek için "Sözleşme taslağı oluşturma/düzenleme", '
    'durumunu değiştirmek için rolünde "Sözleşme durumunu değiştirme (aktive/iptal/tamamla/fesih)" izni olmalı.';

/// Taslağı düzenleyebilen ama durumu değiştiremeyen (ör. Proje Yöneticisi,
/// docs/contracts.md §5.1) kişiye, aktivasyon düğmesinin neden olmadığı.
const kContractNoLifecycleText =
    'Sözleşmeyi aktifleştirme, tamamlama, iptal ve fesih işlemleri için rolünde "Sözleşme durumunu değiştirme '
    '(aktive/iptal/tamamla/fesih)" izni olmalı.';

/// Sözleşmesiz projede, sözleşme oluşturamayan (yalnızca `contracts.read`)
/// kişiye -- düğme yok, neden yok sorusu kalmasın.
const kContractCreateReadOnlyText =
    'Sözleşmeyi yalnızca görüntüleyebilirsin; sözleşme oluşturmak için rolünde "Sözleşme taslağı '
    'oluşturma/düzenleme" izni olmalı.';

/// Kapalı projede sözleşmeyi kapatabilen (lifecycle izni) kişiye: şartlar ve
/// not kilitli, yalnızca kapanış eylemleri açık (backend ile aynı kural).
const kContractLockedClosingText =
    'Proje tamamlandı veya iptal edildi; sözleşme şartları ve dahili not artık değiştirilemez. Sözleşmeyi '
    'yalnızca kapatabilirsin (Tamamla, Feshet veya İptal Et).';

const kChangeOrdersNoAccessText =
    'Ek işleri görüntüleme yetkin yok. Yöneticinden rolüne "Proje finansal verilerini görüntüleme" '
    'iznini eklemesini isteyebilirsin.';

const kChangeOrdersReadOnlyText =
    'Ek işleri yalnızca görüntüleyebilirsin; oluşturmak, göndermek veya iptal etmek için rolünde '
    '"Proje finansal işlemlerini yönetme" izni olmalı.';

/// Web `locked` (proje tamamlandı/iptal) ile aynı kapı: bu durumda hiçbir
/// yazma aksiyonu gösterilmez (ek iş uçları zaten 409 döner).
const kProjectLockedText = kProjectLockedNoticeText;

final _quantityFormat = NumberFormat.decimalPattern('tr_TR')
  ..minimumFractionDigits = 0
  ..maximumFractionDigits = 3;

/// Kalem miktarı, Türkçe ondalıkla ve gereksiz sıfırlar olmadan
/// ("2", "12,5", "0,375").
String formatQuantity(double value) => _quantityFormat.format(value);

/// RFC3339 zaman damgası -> "dd.MM.yyyy HH:mm", İstanbul saatiyle (UTC+3,
/// yaz saati yok). Ana sayfadaki saat kuralıyla aynı (spec D6): cihazın
/// saat diliminden bağımsız, herkes aynı saati görür.
String formatDateTimeTr(String? rfc3339) {
  final parsed = rfc3339 == null ? null : DateTime.tryParse(rfc3339);
  if (parsed == null) return rfc3339 == null || rfc3339.isEmpty ? '-' : rfc3339;
  final t = parsed.toUtc().add(const Duration(hours: 3));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.day)}.${two(t.month)}.${t.year} ${two(t.hour)}:${two(t.minute)}';
}

/// RFC3339 zaman damgası -> "dd.MM.yyyy" (İstanbul günü; gece yarısına
/// yakın UTC damgaları bir önceki güne düşmesin).
String formatDateTr(String? rfc3339) {
  final full = formatDateTimeTr(rfc3339);
  final space = full.indexOf(' ');
  return space < 0 ? full : full.substring(0, space);
}

bool isProjectLocked(Project? project) =>
    project != null && (project.status == 'completed' || project.status == 'cancelled');

/// Oturum henüz yüklenmediyse izin kararı VERİLMEZ (yükleniyor gösterilir)
/// -- aksi halde fail-open `can` yetkisiz kişiye gereksiz bir istek attırır.
bool isAuthPending(AsyncValue<User?> auth) => !auth.hasValue && auth.isLoading;

bool isForbiddenError(Object? error) => error is ApiException && error.isForbidden;

bool isConflictError(Object? error) => error is ApiException && error.kind == ApiErrorKind.conflict;

/// Yazma hatası -> kullanıcı metni. 403 sabit bir cümleye çevrilir; 409
/// (durum başka yerde değişti) ve diğerlerinde backend'in Türkçe mesajı.
String contractCoErrorText(Object error) {
  if (error is ApiException) {
    return error.isForbidden ? 'Bu işlem için yetkin yok.' : error.message;
  }
  return 'Beklenmeyen bir hata oluştu.';
}

void showContractCoSnack(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Onay penceresi -- web `useConfirmDialog` ile aynı başlık/metin/düğme.
Future<bool> showContractCoConfirm(
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

/// Onay + ZORUNLU gerekçe tek pencerede (sözleşme İptal/Fesih -- backend
/// boş gerekçeyi 400 ile reddeder). Onay düğmesi gerekçe yazılana kadar
/// pasiftir. Vazgeçilirse `null`.
Future<String?> showReasonDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required String reasonLabel,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _ReasonDialog(title: title, message: message, confirmLabel: confirmLabel, reasonLabel: reasonLabel),
  );
}

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({required this.title, required this.message, required this.confirmLabel, required this.reasonLabel});

  final String title;
  final String message;
  final String confirmLabel;
  final String reasonLabel;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _controller = TextEditingController();

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
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: widget.reasonLabel, alignLabelWithHint: true),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Vazgeç')),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          onPressed: reason.isEmpty ? null : () => Navigator.of(context).pop(reason),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Detay satırı -- ortak `AppDataRow` (uzun değer kesilmez, etiketin
/// altına tam yazılır). Boş değer soluk "—".
class ContractCoInfoRow extends StatelessWidget {
  const ContractCoInfoRow({super.key, required this.label, this.value, this.valueColor, this.emphasize = false});

  final String label;
  final String? value;
  final Color? valueColor;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final text = value ?? '';
    return AppDataRow(
      label: label,
      value: text.isEmpty ? '—' : text,
      valueColor: text.isEmpty ? AppColors.textMuted : valueColor,
      emphasize: emphasize,
      multiline: true,
    );
  }
}

/// Kısa değerli satır (tutar, oran): etiket kalan genişliği alır, değer
/// kendi genişliğinde ve hiç kesilmez -- `AppDataRow`'un 2:3 bölüşümü
/// "Gerçekleşen Maliyet" / "Ana Sözleşme Bedeli" gibi etiketleri 360 dp'de
/// kırpıyordu.
class ContractCoValueRow extends StatelessWidget {
  const ContractCoValueRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.emphasize = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final base = emphasize
        ? AppTypography.body.copyWith(fontSize: 15, fontWeight: FontWeight.w800)
        : AppTypography.body.copyWith(fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(label, style: AppTypography.metadata, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            value,
            textAlign: TextAlign.right,
            style: base.copyWith(color: valueColor, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}

/// Başlıklı bilgi kartı (başlık + isteğe bağlı sağ aksiyon + satırlar).
class ContractCoCard extends StatelessWidget {
  const ContractCoCard({super.key, required this.title, required this.children, this.trailing});

  final String title;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: AppTypography.cardTitle)),
              ?trailing,
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          ...children,
        ],
      ),
    );
  }
}

/// İşaretli tutar (ek iş +yeşil, eksiltme −kırmızı). Renge tek başına
/// güvenilmez -- işaret her zaman yazılır (`Formatters.signedMoney`).
class SignedMoneyText extends StatelessWidget {
  const SignedMoneyText(this.amount, {super.key, required this.currency, this.style});

  final double amount;
  final String currency;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final color = amount < 0 ? AppColors.danger : (amount > 0 ? AppColors.success : AppColors.textMuted);
    return Text(
      Formatters.signedMoney(amount, currency: currency),
      style: (style ?? AppTypography.body.copyWith(fontWeight: FontWeight.w700))
          .copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Durum notu (ör. "Müşteri yanıtı bekleniyor", "Müşteri reddetti"):
/// renkli ikon + başlık + açıklama. Zemin yalnızca hafif tonlu -- kartın
/// kendisi durum rengine BOYANMAZ.
class ContractCoStatusNote extends StatelessWidget {
  const ContractCoStatusNote({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.lines = const [],
    this.child,
  });

  final IconData icon;
  final Color color;
  final String title;
  final List<String> lines;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTypography.cardTitle.copyWith(color: color)),
                for (final line in lines) ...[
                  const SizedBox(height: 2),
                  Text(line, style: AppTypography.metadata.copyWith(height: 1.35)),
                ],
                if (child != null) ...[const SizedBox(height: AppSpacing.sm), child!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tarih seçici satırı ("YYYY-MM-DD" değer, gösterimde "dd.MM.yyyy").
/// Temizle düğmesi alanı boşaltır (backend'e `null` gider).
class ContractCoDateField extends StatelessWidget {
  const ContractCoDateField({super.key, required this.label, required this.value, required this.onChanged, this.enabled = true});

  final String label;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool enabled;

  static String toIso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final hasValue = value != null && value!.isNotEmpty;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: !enabled
          ? null
          : () async {
              final initial = (hasValue ? DateTime.tryParse(value!) : null) ?? DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: initial,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) onChanged(toIso(picked));
            },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          enabled: enabled,
          suffixIcon: hasValue && enabled
              ? IconButton(
                  tooltip: 'Temizle',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => onChanged(null),
                )
              : const Icon(Icons.calendar_today_outlined, size: 18),
        ),
        child: Text(
          hasValue ? Formatters.date(value) : 'Seçilmedi',
          style: AppTypography.body.copyWith(color: hasValue ? null : AppColors.textMuted),
        ),
      ),
    );
  }
}

/// Liste/detay gövdesinde erişim yok -- ortak [NoAccessView], kaydırılabilir.
class ContractCoNoAccess extends StatelessWidget {
  const ContractCoNoAccess({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => NoAccessView(message: message, scrollable: true);
}
