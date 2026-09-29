import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_form_section.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/unsaved_changes_scope.dart';
import '../../data/projects_providers.dart';
import '../data/ops_team_providers.dart';
import '../domain/ops_dates.dart';
import '../domain/ops_permissions.dart';
import '../domain/schedule_item.dart';
import 'widgets/ops_common.dart';

/// Planlama aşaması ekle / düzenle. Web `ScheduleSection` formu (Aşama adı,
/// Başlangıç, Bitiş) + backend'in zaten kabul ettiği Açıklama; düzenlemede
/// Durum da seçilir (backend'de geçiş grafiği yok -- dört durum her zaman
/// seçilebilir). Yeni aşama listenin SONUNA eklenir (`sort_order =
/// mevcut aşama sayısı`, web ile aynı); düzenleme sırayı korur.
class ScheduleItemFormScreen extends ConsumerStatefulWidget {
  const ScheduleItemFormScreen({super.key, required this.projectId, this.itemId});

  final String projectId;
  final String? itemId;

  bool get isEdit => itemId != null;

  @override
  ConsumerState<ScheduleItemFormScreen> createState() => _ScheduleItemFormScreenState();
}

class _ScheduleItemFormScreenState extends ConsumerState<ScheduleItemFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _description = TextEditingController();
  DateTime? _start;
  DateTime? _end;
  String _status = ScheduleStatus.planned;
  ScheduleItem? _original;
  bool _initialized = false;
  bool _submitting = false;
  bool _dirty = false;
  String? _error;
  String? _dateError;

  @override
  void initState() {
    super.initState();
    _name.addListener(_markDirty);
    _description.addListener(_markDirty);
  }

  void _markDirty() {
    if (_initialized && !_dirty) setState(() => _dirty = true);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _initFrom(List<ScheduleItem> items) {
    if (_initialized) return;
    if (widget.isEdit) {
      for (final s in items) {
        if (s.id == widget.itemId) _original = s;
      }
      final o = _original;
      if (o != null) {
        _name.text = o.name;
        _description.text = o.description;
        _start = parseDay(o.startDate);
        _end = parseDay(o.endDate);
        _status = o.status;
      }
    }
    _initialized = true;
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    final title = Text(widget.isEdit ? 'Aşamayı Düzenle' : 'Yeni Aşama');
    if (user == null && auth.isLoading) return AppPageScaffold(title: title, body: const LoadingState());
    if (!user.can(kProjectOpsManagePermission)) {
      return AppPageScaffold(
        title: title,
        body: const NoAccessView(
          message: 'Planlamayı düzenleme yetkin yok. Yöneticinden rolüne '
              '"Planlama/dosya/fotoğraf/not/ekip yönetme" iznini eklemesini isteyebilirsin.',
        ),
      );
    }
    final projectStatus = ref.watch(projectDetailProvider(widget.projectId)).valueOrNull?.status;
    final locked = projectStatus != null && isProjectLocked(projectStatus);
    final scheduleAsync = ref.watch(opsScheduleProvider(widget.projectId));

    return UnsavedChangesScope(
      dirty: _dirty,
      busy: _submitting,
      child: AppPageScaffold(
        title: title,
        body: scheduleAsync.when(
          loading: () => const LoadingState(),
          error: (e, _) => isOpsForbidden(e)
              ? const NoAccessView(message: kScheduleNoAccessText)
              : ErrorState(error: e, onRetry: () async => ref.invalidate(opsScheduleProvider(widget.projectId))),
          data: (items) {
            _initFrom(items);
            if (widget.isEdit && _original == null) {
              return const EmptyStateView(message: 'Aşama bulunamadı.', icon: Icons.search_off);
            }
            return _buildForm(items, locked: locked);
          },
        ),
      ),
    );
  }

  Widget _buildForm(List<ScheduleItem> items, {required bool locked}) {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
        children: [
          if (locked) ...[const OpsLockedNotice(), const SizedBox(height: AppSpacing.lg)],
          AppFormSection(
            title: 'Aşama Bilgileri',
            children: [
              TextFormField(
                key: const ValueKey('schedule-name'),
                controller: _name,
                enabled: !_submitting,
                inputFormatters: [LengthLimitingTextInputFormatter(200)],
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Aşama adı *', hintText: 'ör. Kaba İnşaat'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Aşama adı zorunludur' : null,
              ),
              TextFormField(
                key: const ValueKey('schedule-description'),
                controller: _description,
                enabled: !_submitting,
                minLines: 2,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Açıklama', alignLabelWithHint: true),
              ),
            ],
          ),
          AppFormSection(
            title: 'Tarihler',
            subtitle: 'Bitiş tarihi geçip açık kalan aşama listede "Gecikti" olarak görünür.',
            children: [
              OpsDateField(
                key: const ValueKey('schedule-start'),
                label: 'Başlangıç',
                value: _start,
                enabled: !_submitting,
                onChanged: (v) => setState(() {
                  _start = v;
                  _dirty = true;
                  _dateError = null;
                }),
              ),
              OpsDateField(
                key: const ValueKey('schedule-end'),
                label: 'Bitiş',
                value: _end,
                enabled: !_submitting,
                errorText: _dateError,
                onChanged: (v) => setState(() {
                  _end = v;
                  _dirty = true;
                  _dateError = null;
                }),
              ),
            ],
          ),
          if (widget.isEdit)
            AppFormSection(
              title: 'Durum',
              children: [
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final s in ScheduleStatus.values)
                      ChoiceChip(
                        label: Text(ScheduleStatus.label(s)),
                        selected: _status == s,
                        onSelected: _submitting
                            ? null
                            : (_) => setState(() {
                                  _status = s;
                                  _dirty = true;
                                }),
                      ),
                  ],
                ),
              ],
            ),
          if (_error != null) ...[
            Text(_error!, style: AppTypography.error),
            const SizedBox(height: AppSpacing.md),
          ],
          PrimaryButton(
            label: widget.isEdit ? 'Kaydet' : 'Aşama Ekle',
            loading: _submitting,
            onPressed: () => _submit(items),
          ),
        ],
      ),
    );
  }

  Future<void> _submit(List<ScheduleItem> items) async {
    final formOk = _formKey.currentState?.validate() ?? false;
    final start = _start;
    final end = _end;
    final dateError = start != null && end != null && end.isBefore(start) ? 'Bitiş tarihi başlangıçtan önce olamaz.' : null;
    setState(() => _dateError = dateError);
    if (!formOk || dateError != null) return;

    final original = _original;
    final input = ScheduleItemInput(
      name: _name.text.trim(),
      description: _description.text.trim(),
      startDate: formatDay(start),
      endDate: formatDay(end),
      status: widget.isEdit ? _status : ScheduleStatus.planned,
      sortOrder: original?.sortOrder ?? items.length,
    );
    setState(() {
      _submitting = true;
      _error = null;
    });
    // Kayıt sürerken sayfa kapanmış olsa bile altta açık kalan liste
    // tazelensin: kapsayıcı ilk await'ten ÖNCE alınır.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final repo = container.read(opsTeamRepositoryProvider);
      if (original != null) {
        await repo.updateScheduleItem(widget.projectId, original.id, input);
      } else {
        await repo.createScheduleItem(widget.projectId, input);
      }
      container.invalidate(opsScheduleProvider(widget.projectId));
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _submitting = false;
      });
      showOpsSnack(context, original != null ? 'Aşama güncellendi.' : 'Aşama eklendi.');
      context.pop();
    } catch (e) {
      if (isOpsConflict(e)) container.invalidate(opsScheduleProvider(widget.projectId));
      if (mounted) {
        setState(() {
          _error = opsErrorText(e);
          _submitting = false;
        });
      }
    }
  }
}
