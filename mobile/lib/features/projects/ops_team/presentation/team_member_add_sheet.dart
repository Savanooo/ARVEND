import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_form_section.dart';
import '../../../../core/widgets/unsaved_changes_scope.dart';
import '../data/ops_team_providers.dart';
import '../domain/ops_dates.dart';
import '../domain/team_member.dart';
import 'widgets/ops_common.dart';

/// "Ekibe Ekle" alt sayfası; eklenen üyeyi döner (vazgeçilirse null).
/// Yalnızca `projects.operations.manage` sahibine ve kilitli olmayan
/// projede gösterilen düğmeden çağrılır. [activeEmployeeIds] seçiciden
/// düşülür (aynı personel aynı anda iki kez aktif olamaz -- backend 409).
Future<ProjectTeamMember?> showTeamMemberAddSheet(
  BuildContext context, {
  required String projectId,
  required Set<String> activeEmployeeIds,
}) {
  return showModalBottomSheet<ProjectTeamMember>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: false,
    builder: (_) => TeamMemberAddSheet(projectId: projectId, activeEmployeeIds: activeEmployeeIds),
  );
}

/// Web formu: Personel* + Görev/rol; backend'in zaten kabul ettiği
/// Başlangıç tarihi ve Not da mobilde sorulur (isteğe bağlı).
class TeamMemberAddSheet extends ConsumerStatefulWidget {
  const TeamMemberAddSheet({super.key, required this.projectId, required this.activeEmployeeIds});

  final String projectId;
  final Set<String> activeEmployeeIds;

  @override
  ConsumerState<TeamMemberAddSheet> createState() => _TeamMemberAddSheetState();
}

class _TeamMemberAddSheetState extends ConsumerState<TeamMemberAddSheet> {
  final _formKey = GlobalKey<FormState>();
  final _roleTitle = TextEditingController();
  final _notes = TextEditingController();
  String? _employeeId;
  DateTime? _startDate;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _roleTitle.dispose();
    _notes.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _employeeId != null || _roleTitle.text.isNotEmpty || _notes.text.isNotEmpty || _startDate != null;

  @override
  Widget build(BuildContext context) {
    final employeesAsync = ref.watch(opsEmployeeOptionsProvider(widget.projectId));
    return UnsavedChangesScope(
      busy: _submitting,
      dirty: _dirty && !_submitting,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Ekibe Ekle', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
                const SizedBox(height: AppSpacing.lg),
                // Tek bölüm: tek alanlı ayrı bir "Personel" bölümü başlığı alan
                // etiketini ("Personel *") tekrar ediyordu.
                AppFormSection(
                  title: 'Ekip Üyesi',
                  children: [
                    employeesAsync.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                        child: LinearProgressIndicator(),
                      ),
                      error: (e, _) => Text(
                        isOpsForbidden(e) ? 'Personel listesini görüntüleme yetkin yok.' : opsErrorText(e),
                        style: AppTypography.error,
                      ),
                      data: (all) {
                        final available = [
                          for (final e in all)
                            if (!widget.activeEmployeeIds.contains(e.id)) e,
                        ];
                        if (available.isEmpty) {
                          return const Text('Ekibe eklenebilecek aktif personel yok.', style: AppTypography.metadata);
                        }
                        EmployeeOption? chosen;
                        for (final e in available) {
                          if (e.id == _employeeId) chosen = e;
                        }
                        return DropdownButtonFormField<String>(
                          key: const ValueKey('team-employee'),
                          initialValue: _employeeId,
                          isExpanded: true,
                          decoration: InputDecoration(
                            labelText: 'Personel *',
                            hintText: 'Personel seç',
                            // Ekip (İK roster'ı) proje erişimi VERMEZ: hesabı
                            // olup projeyi göremeyen kişiye görev atanamaz.
                            helperText: chosen != null && chosen.lacksProjectAccess
                                ? '${chosen.fullName} bu projeyi uygulamada göremez; ekibe eklemek erişim vermez. '
                                    'Görev atanabilmesi için Proje Erişimi\'nden eklenmeli.'
                                : null,
                            helperMaxLines: 3,
                            helperStyle: AppTypography.helper.copyWith(color: AppColors.warning),
                          ),
                          items: [
                            for (final e in available)
                              DropdownMenuItem(
                                value: e.id,
                                child: Text(
                                  e.label + (e.lacksProjectAccess ? kNoProjectAccessSuffix : ''),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _submitting ? null : (v) => setState(() => _employeeId = v),
                          validator: (v) => v == null ? 'Personel seç' : null,
                        );
                      },
                    ),
                    TextFormField(
                      key: const ValueKey('team-role-title'),
                      controller: _roleTitle,
                      enabled: !_submitting,
                      inputFormatters: [LengthLimitingTextInputFormatter(120)],
                      textCapitalization: TextCapitalization.words,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'Görev/rol', hintText: 'ör. Şantiye Şefi'),
                    ),
                    OpsDateField(
                      label: 'Başlangıç tarihi',
                      value: _startDate,
                      enabled: !_submitting,
                      onChanged: (v) => setState(() => _startDate = v),
                    ),
                    TextFormField(
                      key: const ValueKey('team-notes'),
                      controller: _notes,
                      enabled: !_submitting,
                      minLines: 1,
                      maxLines: 3,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'Not', alignLabelWithHint: true),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  Text(_error!, style: AppTypography.error),
                  const SizedBox(height: AppSpacing.md),
                ],
                PrimaryButton(
                  label: 'Ekibe Ekle',
                  loading: _submitting,
                  onPressed: employeesAsync.hasValue ? _submit : null,
                ),
                const SizedBox(height: AppSpacing.sm),
                TextButton(
                  onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                  child: const Text('Vazgeç'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final employeeId = _employeeId;
    if (employeeId == null) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final added = await ref.read(opsTeamRepositoryProvider).addMember(
            widget.projectId,
            TeamMemberInput(
              employeeId: employeeId,
              roleTitle: _roleTitle.text.trim(),
              startDate: formatDay(_startDate),
              notes: _notes.text.trim(),
            ),
          );
      if (mounted) {
        setState(() => _submitting = false);
        Navigator.of(context).pop(added);
      }
    } catch (e) {
      // 409: "bu personel zaten projenin aktif ekibinde" -- backend mesajı.
      if (isOpsConflict(e)) ref.invalidate(opsTeamMembersProvider(widget.projectId));
      if (mounted) {
        setState(() {
          _error = opsErrorText(e);
          _submitting = false;
        });
      }
    }
  }
}
