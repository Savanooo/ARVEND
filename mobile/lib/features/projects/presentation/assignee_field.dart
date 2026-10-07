import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../data/projects_providers.dart';
import '../domain/project.dart';
import '../ops_team/presentation/widgets/ops_common.dart' show kNoProjectAccessSuffix;

/// Görev ve plan formlarının ortak "kime" alanı. Seçilen kişinin uygulama
/// hesabı yoksa bildirimin ona ulaşmayacağını söyler -- yönetici "atadım,
/// haberi olur" sanmasın. Hesabı olup projeyi GÖREMEYEN kişi seçilemez:
/// backend atamayı reddeder (bildirimi açınca 403 görürdü); kişi zaten
/// atanmışsa (erişimi sonradan kaldırıldıysa) seçili kalır ve uyarılır.
class AssigneeField extends ConsumerWidget {
  const AssigneeField({
    super.key,
    required this.projectId,
    required this.value,
    required this.onChanged,
    this.currentName = '',
    this.label = 'Atanan Kişi (opsiyonel)',
    this.enabled = true,
  });

  final String projectId;

  /// Seçili personel kimliği (null = atanmamış).
  final String? value;

  /// Kayıttaki ad -- seçili kişi artık aktif listede yoksa (pasife
  /// alınmış) seçenek olarak yine görünsün diye.
  final String currentName;
  final String label;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(projectAssigneesProvider(projectId));
    final people = async.valueOrNull;
    if (people == null) {
      return InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          errorText: async.hasError ? 'Personel listesi alınamadı' : null,
          suffixIcon: async.hasError
              ? IconButton(
                  tooltip: 'Tekrar dene',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => ref.invalidate(projectAssigneesProvider(projectId)),
                )
              : const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
        ),
        child: Text(currentName.isNotEmpty ? currentName : '— Atanmadı —'),
      );
    }

    final selected = value == null || value!.isEmpty ? null : value;
    Assignee? chosen;
    for (final p in people) {
      if (p.id == selected) chosen = p;
    }
    final missing = selected != null && chosen == null;
    String? helper;
    var warn = false;
    if (chosen != null) {
      if (!chosen.hasAccount) {
        helper = 'Bu kişinin uygulama hesabı yok; bildirim gitmez.';
        warn = true;
      } else if (chosen.lacksProjectAccess) {
        helper = '${chosen.fullName} bu projeyi göremiyor; yeni görev atanamaz. '
            'Proje Erişimi\'nden eklenmeli.';
        warn = true;
      } else {
        helper = '${chosen.fullName} bildirim alır.';
      }
    }

    return DropdownButtonFormField<String>(
      key: ValueKey('assignee-$projectId-$selected'),
      initialValue: selected ?? '',
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 3,
        helperStyle: warn ? AppTypography.helper.copyWith(color: AppColors.warning) : null,
      ),
      items: [
        const DropdownMenuItem(value: '', child: Text('— Atanmadı —')),
        if (missing)
          DropdownMenuItem(
            value: selected,
            child: Text('${currentName.isNotEmpty ? currentName : 'Kayıtlı kişi'} (pasif)', overflow: TextOverflow.ellipsis),
          ),
        for (final p in people)
          DropdownMenuItem(
            value: p.id,
            // Projeyi göremeyen hesap yeni atama olarak seçilemez; mevcut
            // atama ise seçili kalabilsin.
            enabled: !p.lacksProjectAccess || p.id == selected,
            child: Text(
              [p.fullName, if (p.position.isNotEmpty) p.position].join(' · ') +
                  (!p.hasAccount
                      ? ' (uygulaması yok)'
                      : p.lacksProjectAccess
                          ? kNoProjectAccessSuffix
                          : ''),
              overflow: TextOverflow.ellipsis,
              style: p.lacksProjectAccess && p.id != selected
                  ? const TextStyle(color: AppColors.textMuted)
                  : null,
            ),
          ),
      ],
      onChanged: enabled ? (v) => onChanged((v == null || v.isEmpty) ? null : v) : null,
    );
  }
}
