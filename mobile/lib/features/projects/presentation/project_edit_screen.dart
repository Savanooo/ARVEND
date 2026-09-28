import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/access_notices.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_data_row.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/app_section_header.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../data/project_edit_repository.dart';
import '../data/projects_providers.dart';
import '../domain/project_edit.dart';

const kPermProjectsUpdate = 'projects.update';

const _noAccessMessage = 'Proje bilgilerini düzenleme yetkin yok; rolünde "Proje bilgilerini düzenleme" izni olmalı.';

/// Proje bilgilerini düzenle (web `projeler/[id]/duzenle`). Yalnızca
/// `projects.update` ile açılır (katı `canAccess`); izin yoksa veri
/// çekilmez. Sözleşme bedeli/para birimi/kaynak teklif/müşteri bilgisi
/// değiştirilemez, yalnızca bilgi olarak gösterilir.
class ProjectEditScreen extends ConsumerWidget {
  const ProjectEditScreen({super.key, required this.projectId});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authControllerProvider).valueOrNull;
    if (!user.canAccess(kPermProjectsUpdate)) {
      return const AppPageScaffold(
        title: Text('Projeyi Düzenle'),
        body: NoAccessView(message: _noAccessMessage),
      );
    }

    final projectAsync = ref.watch(projectEditableProvider(projectId));
    return AppPageScaffold(
      title: const Text('Projeyi Düzenle'),
      body: projectAsync.when(
        data: (p) => ProjectEditForm(
          project: p,
          // Para bilgisi yalnızca finans görüntüleme izni olana (proje
          // detayındaki Finans grubu ile aynı ilke).
          showContractAmount: user.canAccess('projects.finance.read'),
        ),
        loading: () => const LoadingState(),
        error: (err, _) => err is ApiException && err.isForbidden
            ? const NoAccessView(message: _noAccessMessage)
            : ErrorState(error: err, onRetry: () async => ref.invalidate(projectEditableProvider(projectId))),
      ),
    );
  }
}

class ProjectEditForm extends ConsumerStatefulWidget {
  const ProjectEditForm({super.key, required this.project, required this.showContractAmount});

  final ProjectEditable project;
  final bool showContractAmount;

  @override
  ConsumerState<ProjectEditForm> createState() => _ProjectEditFormState();
}

class _ProjectEditFormState extends ConsumerState<ProjectEditForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _projectType;
  late final TextEditingController _description;
  late final TextEditingController _internalNotes;
  late String _status;
  DateTime? _startDate;
  DateTime? _endDate;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final p = widget.project;
    _name = TextEditingController(text: p.name);
    _projectType = TextEditingController(text: p.projectType);
    _description = TextEditingController(text: p.description);
    _internalNotes = TextEditingController(text: p.internalNotes);
    _status = p.status;
    _startDate = p.startDate == null ? null : DateTime.tryParse(p.startDate!);
    _endDate = p.endDate == null ? null : DateTime.tryParse(p.endDate!);
  }

  @override
  void dispose() {
    _name.dispose();
    _projectType.dispose();
    _description.dispose();
    _internalNotes.dispose();
    super.dispose();
  }

  String _statusLabel(String s) => StatusRegistry.project[s]?.$1 ?? s;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final p = widget.project;
    // İptal geri alınamaz (terminal durum) -- yanlışlıkla seçilmesine karşı onay.
    if (_status == 'cancelled' && p.status != 'cancelled') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Projeyi İptal Et'),
          content: const Text(
            'İptal edilen bir proje yeniden açılamaz. Durumu “İptal Edildi” olarak kaydetmek istiyor musun?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Vazgeç')),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              child: const Text('İptal Et'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    // Kayıt sürerken ekran kapanamaz (UnsavedChangesScope); yine de proje
    // detayı/listesi ekrana bağlı kalmadan tazelensin diye kapsayıcı
    // ilk await'ten ÖNCE alınır.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await container
          .read(projectEditRepositoryProvider)
          .update(
            p.id,
            ProjectEditInput(
              name: _name.text,
              projectType: _projectType.text,
              status: _status,
              startDate: _startDate == null ? null : formatApiDate(_startDate!),
              endDate: _endDate == null ? null : formatApiDate(_endDate!),
              description: _description.text,
              internalNotes: _internalNotes.text,
            ),
          );
      container.invalidate(projectDetailProvider(p.id));
      container.invalidate(projectsListProvider);
      container.invalidate(customerProjectsProvider);
      container.invalidate(projectEditableProvider(p.id));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Proje bilgileri güncellendi.')));
      if (context.canPop()) {
        context.pop(true);
      } else {
        context.go('/projeler/${p.id}');
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.isForbidden ? _noAccessMessage : e.message);
    } catch (_) {
      // ApiClient hataları ApiException'a çevirir; buraya düşen beklenmedik
      // bir hata da form içinde gösterilir, ekran çökmez.
      if (mounted) setState(() => _error = 'Beklenmeyen bir hata oluştu.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.project;
    final options = projectStatusOptions(p.status);
    return UnsavedChangesScope(
      busy: _saving,
      child: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
          children: [
            // Değiştirilemeyen bilgiler bağlam olarak EN ÜSTTE; birincil
            // "Kaydet" düğmesi sayfanın son öğesi.
            _FrozenInfoCard(project: p, showContractAmount: widget.showContractAmount),
            const SizedBox(height: AppSpacing.xl),
            AppFormSection(
              title: 'Proje Bilgileri',
              children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Proje Adı *'),
                  textCapitalization: TextCapitalization.sentences,
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Proje adı zorunludur' : null,
                ),
                TextFormField(
                  controller: _projectType,
                  decoration: const InputDecoration(labelText: 'Proje Tipi', hintText: 'örn. İnşaat, Tadilat, Altyapı'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: options.contains(_status) ? _status : options.first,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Durum',
                    helperText: options.length == 1
                        ? '${_statusLabel(p.status)} durumundaki bir proje yeniden açılamaz.'
                        : null,
                    helperMaxLines: 2,
                  ),
                  items: [for (final s in options) DropdownMenuItem(value: s, child: Text(_statusLabel(s)))],
                  onChanged: options.length == 1 ? null : (v) => setState(() => _status = v ?? p.status),
                ),
              ],
            ),
            AppFormSection(
              title: 'Tarihler',
              children: [
                _DateField(
                  label: 'Başlangıç Tarihi',
                  value: _startDate,
                  onChanged: (d) => setState(() => _startDate = d),
                ),
                _DateField(label: 'Planlanan Bitiş', value: _endDate, onChanged: (d) => setState(() => _endDate = d)),
              ],
            ),
            AppFormSection(
              title: 'Açıklamalar',
              children: [
                TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(labelText: 'Açıklama'),
                  maxLines: 3,
                  minLines: 1,
                ),
                TextFormField(
                  controller: _internalNotes,
                  decoration: const InputDecoration(labelText: 'Dahili Notlar (müşteri görmez)'),
                  maxLines: 3,
                  minLines: 1,
                ),
              ],
            ),
            if (_error != null) ...[Text(_error!, style: AppTypography.error), const SizedBox(height: AppSpacing.md)],
            PrimaryButton(label: 'Değişiklikleri Kaydet', loading: _saving, onPressed: _submit),
          ],
        ),
      ),
    );
  }
}

/// Web'deki "Değiştirilemeyen Bilgiler" kartı.
class _FrozenInfoCard extends StatelessWidget {
  const _FrozenInfoCard({required this.project, required this.showContractAmount});

  final ProjectEditable project;
  final bool showContractAmount;

  @override
  Widget build(BuildContext context) {
    final p = project;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppSectionHeader(title: 'Değiştirilemeyen Bilgiler'),
          const SizedBox(height: AppSpacing.xs),
          AppDataRow(label: 'Proje No', value: p.projectNo),
          AppDataRow(label: 'Müşteri', value: p.customerName.isEmpty ? '-' : p.customerName),
          if (showContractAmount)
            AppDataRow(
              label: 'Sözleşme Bedeli',
              value: Formatters.money(p.contractAmount, currency: p.currency),
            ),
          AppDataRow(label: 'Kaynak Teklif', value: p.sourceOfferNo.isEmpty ? '-' : p.sourceOfferNo),
          if (p.sourceOfferNo.isNotEmpty) AppDataRow(label: 'Revizyon', value: '#${p.sourceRevisionNo}'),
          const Divider(height: AppSpacing.xl),
          const Text(
            'Bu alanlar kabul edilen teklife ait dondurulmuş bilgilerdir. Sözleşme bedeli değişiklikleri '
            '“Ek İşler” ile yapılır.',
            style: AppTypography.helper,
          ),
        ],
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.value, required this.onChanged});

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        isEmpty: value == null,
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: value != null
              ? IconButton(
                  tooltip: 'Tarihi temizle',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => onChanged(null),
                )
              : const Icon(Icons.calendar_today_outlined, size: 18),
        ),
        child: value == null ? null : Text(Formatters.date(formatApiDate(value!)), style: AppTypography.body),
      ),
    );
  }
}
