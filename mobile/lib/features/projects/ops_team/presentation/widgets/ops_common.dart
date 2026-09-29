import 'package:flutter/material.dart';

import '../../../../../core/errors/api_exception.dart';
import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_radius.dart';
import '../../../../../core/theme/app_typography.dart';
import '../../../../../core/widgets/access_notices.dart';
import '../../../../../core/widgets/status_badge.dart';
import '../../../domain/project_lock_text.dart';
import '../../domain/ops_dates.dart';
import '../../domain/project_access.dart';
import '../../domain/schedule_item.dart';

// ---------- Metinler (web ile aynı dil) ----------

/// Tüm proje modülleriyle aynı kilit cümlesi (bkz. project_lock_text.dart).
const kOpsLockedText = kProjectLockedNoticeText;

const kScheduleReadOnlyText = 'Planlamayı yalnızca görüntüleyebilirsin; aşama eklemek veya güncellemek için '
    'rolünde "Planlama/dosya/fotoğraf/not/ekip yönetme" izni olmalı.';

const kScheduleNoAccessText = 'Planlamayı görüntüleme yetkin yok. Yöneticinden rolüne '
    '"Planlama/dosya/fotoğraf/not/ekip görüntüleme" iznini eklemesini isteyebilirsin.';

const kTeamReadOnlyText = 'Proje ekibini yalnızca görüntüleyebilirsin; ekibe personel eklemek veya çıkarmak için '
    'rolünde "Planlama/dosya/fotoğraf/not/ekip yönetme" izni olmalı.';

/// operations.manage var ama personel listesi (employees.read) yok: ekipten
/// çıkarabilir, yeni personel ekleyemez.
const kTeamNoEmployeesReadText = 'Ekipten çıkarabilirsin; ekibe personel eklemek için rolünde ayrıca "Personeli '
    'görüntüleme" izni olmalı.';

/// projects.access.manage var ama kullanıcı listesi (yalnızca Sahip/Yönetici)
/// yok: mevcut erişimleri düzenleyebilir, yeni kullanıcı ekleyemez.
const kAccessNoUserListText = 'Mevcut erişimleri düzenleyebilirsin; yeni kullanıcıya erişim vermek için kullanıcı '
    'listesini görebilmen gerekir (yalnızca Sahip/Yönetici rolü, "Kullanıcıları görüntüleme" izni).';

const kTeamNoAccessText = 'Proje ekibini görüntüleme yetkin yok. Yöneticinden rolüne '
    '"Planlama/dosya/fotoğraf/not/ekip görüntüleme" iznini eklemesini isteyebilirsin.';

const kAccessReadOnlyText = 'Proje erişimini yalnızca görüntüleyebilirsin; kullanıcı eklemek, rolünü değiştirmek '
    'veya erişimini kaldırmak için rolünde "Proje erişimini yönetme (ekle/çıkar)" izni olmalı.';

const kAccessNoAccessText = 'Proje erişim listesini görüntüleme yetkin yok. Yöneticinden rolüne '
    '"Proje erişim listesini görüntüleme" iznini eklemesini isteyebilirsin.';

/// Web `ProjectAccessSection` açıklaması ile aynı.
const kAccessExplainText = 'Sahip/Yönetici rolündeki kullanıcılar tüm projeleri koşulsuz görür; burada yalnızca '
    'Proje Yöneticisi/Finans/Saha rollerindeki kullanıcıların BU projeye erişimi yönetilir.';

/// backend/docs/authorization.md §3: proje rolü yalnızca etikettir.
const kProjectRoleHelpText =
    'Proje rolü proje içi bir etikettir; kişinin neleri yapabileceğini organizasyon rolü belirler.';

// ---------- Hata yardımcıları ----------

bool isOpsForbidden(Object? error) => error is ApiException && error.isForbidden;

bool isOpsConflict(Object? error) => error is ApiException && error.kind == ApiErrorKind.conflict;

/// Yazma işlemlerinde gösterilecek metin: 403 sabit bir cümleye çevrilir,
/// diğer hatalarda backend'in (Türkçe) mesajı gösterilir (ör. 409 "bu
/// personel zaten projenin aktif ekibinde").
String opsErrorText(Object error) {
  if (error is ApiException) {
    return error.isForbidden ? 'Bu işlem için yetkin yok.' : error.message;
  }
  return 'Beklenmeyen bir hata oluştu.';
}

void showOpsSnack(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

// ---------- Durum rozetleri ----------

/// Planlama durumu -> rozet. Web `SCHEDULE_STATUS` tonları; "Devam Ediyor"
/// web'de gold, mobilde marka rengi durum anlamı taşımadığı için (bkz.
/// StatusTone) proje "Aktif" durumuyla aynı `info`.
const kScheduleStatusRegistry = {
  ScheduleStatus.planned: ('Planlandı', StatusTone.muted),
  ScheduleStatus.active: ('Devam Ediyor', StatusTone.info),
  ScheduleStatus.completed: ('Tamamlandı', StatusTone.success),
  ScheduleStatus.cancelled: ('İptal', StatusTone.danger),
};

Color scheduleStatusColor(String status) => switch (status) {
      ScheduleStatus.active => AppColors.info,
      ScheduleStatus.completed => AppColors.success,
      ScheduleStatus.cancelled => AppColors.danger,
      _ => AppColors.textMuted,
    };

Widget scheduleStatusBadge(String status) => StatusRegistry.build(status, kScheduleStatusRegistry);

/// Proje rolü rozeti -- yalnızca etiket; "Proje Yöneticisi" vurgulu.
Widget projectRoleBadge(String role) => StatusBadge(
      label: ProjectRole.label(role),
      tone: role == ProjectRole.projectManager ? StatusTone.info : StatusTone.muted,
    );

// ---------- Tarih gösterimi ----------

String _two(int n) => n.toString().padLeft(2, '0');

/// "2026-09-01" -> "01.09.2026"; boşsa "—".
String dayText(String? value) {
  final d = parseDay(value);
  if (d == null) return '—';
  return '${_two(d.day)}.${_two(d.month)}.${d.year}';
}

/// Aşama tarih aralığı: "01.09.2026 → 30.09.2026" (web ile aynı ok).
String dayRangeText(String? start, String? end) {
  if ((start == null || start.isEmpty) && (end == null || end.isEmpty)) return 'Tarih belirtilmedi';
  return '${dayText(start)} → ${dayText(end)}';
}

// ---------- Ortak bileşenler ----------

/// Kilitli proje notu (tamamlanmış/iptal edilmiş).
class OpsLockedNotice extends StatelessWidget {
  const OpsLockedNotice({super.key});

  @override
  Widget build(BuildContext context) => const ReadOnlyNotice(kOpsLockedText);
}

/// Onay penceresi -- web `useConfirmDialog` ile aynı düzen (Vazgeç + eylem).
Future<bool> confirmOpsAction(
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

/// Ad baş harfleri dairesi (ekip/erişim satırları).
class OpsInitialsAvatar extends StatelessWidget {
  const OpsInitialsAvatar({super.key, required this.name, this.muted = false});

  final String name;
  final bool muted;

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final first = parts.first.characters.first;
    final last = parts.length > 1 ? parts.last.characters.first : '';
    return '$first$last';
  }

  @override
  Widget build(BuildContext context) {
    final color = muted ? AppColors.textMuted : AppColors.gold;
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
      child: Text(
        _initials,
        style: AppTypography.helper.copyWith(color: color, fontWeight: FontWeight.w800, fontSize: 12.5),
      ),
    );
  }
}

/// Seçilebilir tarih alanı (standart alan dekorasyonu; temizlenebilir) --
/// görev formundaki `_DueDateField` deseni.
class OpsDateField extends StatelessWidget {
  const OpsDateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.errorText,
    this.enabled = true,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final String? errorText;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final v = value;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: !enabled
          ? null
          : () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: v ?? istanbulToday(),
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) onChanged(DateTime.utc(picked.year, picked.month, picked.day));
            },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          errorText: errorText,
          errorMaxLines: 2,
          enabled: enabled,
          suffixIcon: v != null && enabled
              ? IconButton(
                  tooltip: 'Tarihi temizle',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => onChanged(null),
                )
              : const Icon(Icons.calendar_today_outlined, size: 18),
        ),
        isEmpty: v == null,
        child: v == null ? null : Text('${_two(v.day)}.${_two(v.month)}.${v.year}', style: AppTypography.body),
      ),
    );
  }
}

/// Liste içi küçük boş durum kartı.
class OpsEmptyCard extends StatelessWidget {
  const OpsEmptyCard(this.text, {super.key, this.icon = Icons.inbox_outlined});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Icon(icon, color: AppColors.textMuted, size: 28),
          const SizedBox(height: 8),
          Text(text, style: AppTypography.metadata, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
