import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/errors/api_exception.dart';
import '../../../../core/files/file_share.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_card.dart';
import '../../../../core/widgets/app_form_section.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/app_sheet.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/unsaved_changes_scope.dart';
import '../../../auth/domain/user.dart';
import '../../../subcontractors/presentation/subcontractor_picker_sheet.dart';
import '../../data/projects_providers.dart';
import '../../domain/project.dart' show ProjectPhoto;
import '../../ops_team/domain/ops_dates.dart';
import '../../ops_team/domain/ops_permissions.dart';
import '../../ops_team/presentation/widgets/ops_common.dart';
import '../../presentation/project_photo_gallery.dart';
import '../daily_report_paths.dart';
import '../data/daily_report_repository.dart';
import '../domain/daily_report.dart';
import 'daily_reports_tab.dart' show dailyReportStatusBadge, kDailyReportNoAccessText;

const _kSuppliersRead = 'organization.suppliers.read';

/// `/projeler/:id/gunluk-rapor/:date` -- bir günün şantiye raporu. Yazma
/// izni (`projects.operations.manage`) olan ve proje açıkken form; aksi
/// halde okuma görünümü. O gün tamamlanan görevler ve çekilen fotoğraflar
/// sunucudan gelir (formda girilmez). "Kaydet ve Gönder" yöneticilere
/// bildirir; gönderilmiş rapor da düzeltilebilir. PDF paylaşım menüsüyle
/// (WhatsApp, e-posta) gider.
class DailyReportScreen extends ConsumerStatefulWidget {
  const DailyReportScreen({super.key, required this.projectId, required this.date});

  final String projectId;

  /// YYYY-AA-GG.
  final String date;

  @override
  ConsumerState<DailyReportScreen> createState() => _DailyReportScreenState();
}

class _SubRow {
  _SubRow(this.sub)
      : workers = TextEditingController(text: '${sub.workers}'),
        note = TextEditingController(text: sub.workNote);

  final DailyReportSubcontractor sub;
  final TextEditingController workers;
  final TextEditingController note;

  void dispose() {
    workers.dispose();
    note.dispose();
  }
}

class _DailyReportScreenState extends ConsumerState<DailyReportScreen> {
  final _temp = TextEditingController();
  final _ownWorkers = TextEditingController();
  final _workDone = TextEditingController();
  final _issues = TextEditingController();
  final _materials = TextEditingController();
  final _notes = TextEditingController();
  String _weather = '';
  final List<_SubRow> _subs = [];

  /// Formun en son hangi sunucu kopyasından doldurulduğu (updated_at); yeni
  /// bir kopya gelince (kaydetme/gönderme sonrası) yeniden doldurulur.
  String? _filledFrom;
  bool _dirty = false;
  bool _saving = false;
  bool _submitting = false;
  bool _pdfLoading = false;

  DailyReportKey get _key => (projectId: widget.projectId, date: widget.date);

  @override
  void dispose() {
    for (final c in [_temp, _ownWorkers, _workDone, _issues, _materials, _notes]) {
      c.dispose();
    }
    for (final r in _subs) {
      r.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  void _fill(DailyReport r) {
    final marker = '${r.exists}|${r.updatedAt}|${r.status}';
    if (_filledFrom == marker) return;
    _filledFrom = marker;
    _weather = r.weather;
    _temp.text = r.temperatureC?.toString() ?? '';
    // Yazılmamış gün: kendi ekibimiz puantajdan önerilir.
    _ownWorkers.text = r.exists ? '${r.ownWorkers}' : (r.suggestedOwnWorkers > 0 ? '${r.suggestedOwnWorkers}' : '');
    _workDone.text = r.workDone;
    _issues.text = r.issues;
    _materials.text = r.materials;
    _notes.text = r.notes;
    for (final s in _subs) {
      s.dispose();
    }
    _subs
      ..clear()
      ..addAll(r.subcontractors.map(_SubRow.new));
    _dirty = false;
  }

  int _int(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;

  /// Kaydedilecek gövde; geçersizse kullanıcıya gösterilecek mesaj.
  (DailyReportInput?, String?) _input() {
    final tempText = _temp.text.trim();
    int? temp;
    if (tempText.isNotEmpty) {
      temp = int.tryParse(tempText);
      if (temp == null || temp < -50 || temp > 60) return (null, 'Sıcaklık -50 ile 60 arasında olmalı.');
    }
    return (
      DailyReportInput(
        weather: _weather,
        temperatureC: temp,
        ownWorkers: _int(_ownWorkers),
        workDone: _workDone.text.trim(),
        issues: _issues.text.trim(),
        materials: _materials.text.trim(),
        notes: _notes.text.trim(),
        subcontractors: [
          for (final r in _subs) r.sub.copyWith(workers: _int(r.workers), workNote: r.note.text.trim()),
        ],
      ),
      null,
    );
  }

  void _toast(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Kaydeder; başarıda sunucunun yeni kopyası.
  Future<DailyReport?> _save({bool quiet = false}) async {
    final (input, error) = _input();
    if (input == null) {
      _toast(error!);
      return null;
    }
    setState(() => _saving = true);
    try {
      final saved = await ref.read(dailyReportRepositoryProvider).save(widget.projectId, widget.date, input);
      ref.invalidate(dailyReportsProvider(widget.projectId));
      if (!mounted) return saved;
      setState(() {
        _filledFrom = null;
        _fill(saved);
      });
      ref.invalidate(dailyReportProvider(_key));
      if (!quiet) _toast('Rapor kaydedildi.');
      return saved;
    } on ApiException catch (e) {
      _toast(e.message);
      return null;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _submit(DailyReport current) async {
    final ok = await confirmOpsAction(
      context,
      title: 'Raporu Gönder',
      message: '${Formatters.longDate(widget.date)} raporu kaydedilip yöneticilere gönderilsin mi? '
          'Gönderdikten sonra da düzeltebilirsin.',
      confirmLabel: 'Gönder',
    );
    if (!ok || !mounted) return;
    setState(() => _submitting = true);
    try {
      if (_dirty || !current.exists) {
        if (await _save(quiet: true) == null) return;
      }
      final sent = await ref.read(dailyReportRepositoryProvider).submit(widget.projectId, widget.date);
      ref.invalidate(dailyReportsProvider(widget.projectId));
      if (!mounted) return;
      setState(() {
        _filledFrom = null;
        _fill(sent);
      });
      ref.invalidate(dailyReportProvider(_key));
      _toast('Rapor gönderildi.');
    } on ApiException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _sharePdf() async {
    if (_dirty) {
      _toast('Önce değişiklikleri kaydet; PDF kaydedilmiş raporu paylaşır.');
      return;
    }
    setState(() => _pdfLoading = true);
    try {
      final bytes = await ref.read(dailyReportRepositoryProvider).pdf(widget.projectId, widget.date);
      final project = ref.read(projectDetailProvider(widget.projectId)).valueOrNull;
      final no = (project?.projectNo ?? '').replaceAll(RegExp(r'[/\s]'), '-');
      final error = await ref.read(fileSharerProvider).shareFile(
            'Gunluk-Rapor-${no.isEmpty ? 'proje' : no}-${widget.date}.pdf',
            bytes,
            mimeType: 'application/pdf',
            text: 'Günlük şantiye raporu · ${project?.name ?? ''} · ${Formatters.date(widget.date)}',
          );
      if (error != null) _toast(error);
    } on ApiException catch (e) {
      _toast(e.message);
    } on Exception {
      _toast('PDF paylaşılamadı. Tekrar dene.');
    } finally {
      if (mounted) setState(() => _pdfLoading = false);
    }
  }

  Future<void> _goToDay(DateTime day) async {
    if (_dirty && !await confirmDiscardChanges(context)) return;
    if (!mounted) return;
    context.pushReplacement(dailyReportPath(widget.projectId, formatDay(day)!));
  }

  Future<void> _addSubcontractor(DailyReport report, User? user) async {
    final taken = _subs.map((r) => r.sub.supplierId).toSet();
    final options = report.subcontractorOptions.where((o) => !taken.contains(o.supplierId)).toList();
    final canBrowse = user.canAccess(_kSuppliersRead);
    final picked = await showAppSheet<DailyReportSubcontractor>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => _SubcontractorOptionsSheet(
        options: options,
        onBrowse: canBrowse
            ? () async {
                final card = await showSubcontractorPickerSheet(sheetContext);
                if (card != null && sheetContext.mounted) {
                  Navigator.of(sheetContext).pop(
                    DailyReportSubcontractor(
                      supplierId: card.id,
                      name: card.legalName,
                      specialty: card.specialty,
                      workers: 0,
                    ),
                  );
                }
              }
            : null,
      ),
    );
    if (picked == null || !mounted) return;
    if (taken.contains(picked.supplierId)) {
      _toast('${picked.name} zaten raporda.');
      return;
    }
    setState(() {
      _subs.add(_SubRow(picked.copyWith(workers: picked.workers > 0 ? picked.workers : 1)));
      _dirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    final title = Text('Günlük Rapor · ${Formatters.date(widget.date)}');
    if (user == null && auth.isLoading) return AppPageScaffold(title: title, body: const LoadingState());
    if (!user.can(kProjectOpsReadPermission)) {
      return AppPageScaffold(title: title, body: const NoAccessView(message: kDailyReportNoAccessText));
    }
    final day = parseDay(widget.date);
    if (day == null) {
      return AppPageScaffold(
        title: const Text('Günlük Rapor'),
        body: const NoAccessView(title: 'Geçersiz tarih', message: 'Bu bağlantıdaki tarih okunamadı.'),
      );
    }
    final today = istanbulToday();
    final isFuture = day.isAfter(today);
    final status = ref.watch(projectDetailProvider(widget.projectId)).valueOrNull?.status;
    final locked = status == null ? null : isProjectLocked(status);
    final canWrite = user.can(kProjectOpsManagePermission) && locked == false && !isFuture;
    final async = ref.watch(dailyReportProvider(_key));
    // Sunucudan yeni bir kopya gelince (tazeleme) form yeniden dolar --
    // build dışında ve kaydedilmemiş düzenleme yoksa. İlk dolum form henüz
    // çizilmeden (alanların dinleyicisi yokken) burada yapılır.
    ref.listen<AsyncValue<DailyReport>>(dailyReportProvider(_key), (_, next) {
      final r = next.valueOrNull;
      if (r == null || _saving || _submitting || _dirty) return;
      setState(() => _fill(r));
    });
    final report = async.valueOrNull;
    if (report != null && _filledFrom == null) _fill(report);
    final busy = _saving || _submitting;

    Future<void> refresh() async {
      ref.invalidate(dailyReportProvider(_key));
      try {
        await ref.read(dailyReportProvider(_key).future);
      } catch (_) {
        // Hata gövdede gösterilir.
      }
    }

    return UnsavedChangesScope(
      dirty: _dirty,
      busy: busy,
      child: AppPageScaffold(
        title: title,
        actions: [
          if (report != null && report.exists)
            IconButton(
              key: const ValueKey('gunluk-rapor-pdf'),
              tooltip: 'PDF paylaş',
              onPressed: _pdfLoading ? null : _sharePdf,
              icon: _pdfLoading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.ios_share),
            ),
        ],
        body: AsyncStateView<DailyReport>(
          value: async,
          onRetry: refresh,
          data: (context, r) => Column(
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: refresh,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xl),
                    children: [
                      _DayHeader(
                        day: day,
                        canGoNext: day.isBefore(today),
                        report: r,
                        onPrev: () => _goToDay(day.subtract(const Duration(days: 1))),
                        onNext: () => _goToDay(day.add(const Duration(days: 1))),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      if (locked == true) ...[
                        const OpsLockedNotice(),
                        const SizedBox(height: AppSpacing.md),
                      ] else if (isFuture) ...[
                        const ReadOnlyNotice('İleri bir günün raporu yazılamaz.'),
                        const SizedBox(height: AppSpacing.md),
                      ] else if (!user.can(kProjectOpsManagePermission)) ...[
                        const ReadOnlyNotice('Raporu yalnızca görüntüleyebilirsin; yazmak için operasyon yönetme yetkisi gerekir.'),
                        const SizedBox(height: AppSpacing.md),
                      ],
                      if (canWrite)
                        ..._form(r, user)
                      else if (!r.exists)
                        const OpsEmptyCard('Bu günün raporu yazılmamış.', icon: Icons.assignment_outlined)
                      else
                        _ReadOnlyReport(report: r),
                      const SizedBox(height: AppSpacing.lg),
                      _AutoSection(
                        projectId: widget.projectId,
                        report: r,
                        // Galeriden silinen fotoğraf rapordan (ve PDF'ten) da
                        // düşer. Form yeniden DOLMAZ (bkz. _fill işareti).
                        onPhotoDeleted: () {
                          ref.invalidate(dailyReportProvider(_key));
                          ref.invalidate(dailyReportsProvider(widget.projectId));
                        },
                      ),
                    ],
                  ),
                ),
              ),
              if (canWrite)
                SafeArea(
                  top: false,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
                    decoration: const BoxDecoration(
                      color: AppColors.surface,
                      border: Border(top: BorderSide(color: AppColors.border)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: SecondaryButton(
                            key: const ValueKey('gunluk-rapor-kaydet'),
                            label: 'Kaydet',
                            icon: Icons.save_outlined,
                            loading: _saving && !_submitting,
                            onPressed: busy ? null : _save,
                          ),
                        ),
                        if (!r.isSubmitted) ...[
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: PrimaryButton(
                              key: const ValueKey('gunluk-rapor-gonder'),
                              label: 'Kaydet ve Gönder',
                              icon: Icons.send_outlined,
                              loading: _submitting,
                              onPressed: busy ? null : () => _submit(r),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _form(DailyReport r, User? user) {
    final ownCount = _int(_ownWorkers);
    final subCount = _subs.fold<int>(0, (sum, s) => sum + _int(s.workers));
    return [
      AppFormSection(
        title: 'Hava',
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final e in kDailyReportWeathers.entries)
                ChoiceChip(
                  key: ValueKey('gunluk-rapor-hava-${e.key}'),
                  avatar: Icon(dailyReportWeatherIcon(e.key), size: 18),
                  label: Text(e.value),
                  selected: _weather == e.key,
                  onSelected: (on) => setState(() {
                    _weather = on ? e.key : '';
                    _dirty = true;
                  }),
                ),
            ],
          ),
          SizedBox(
            width: 160,
            child: TextField(
              key: const ValueKey('gunluk-rapor-sicaklik'),
              controller: _temp,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^-?\d{0,2}'))],
              decoration: const InputDecoration(labelText: 'Sıcaklık', suffixText: '°C', isDense: true),
              onChanged: (_) => _markDirty(),
            ),
          ),
        ],
      ),
      AppFormSection(
        title: 'Sahadaki Ekip',
        subtitle: 'Toplam ${ownCount + subCount} kişi',
        children: [
          _CountField(
            key: const ValueKey('gunluk-rapor-kendi-ekip'),
            label: 'Kendi ekibimiz',
            controller: _ownWorkers,
            onChanged: () => setState(() => _dirty = true),
            helper: r.suggestedOwnWorkers > 0 ? 'Puantaja göre ${r.suggestedOwnWorkers} kişi geldi' : null,
            onUseHelper: r.suggestedOwnWorkers > 0 && ownCount != r.suggestedOwnWorkers
                ? () => setState(() {
                      _ownWorkers.text = '${r.suggestedOwnWorkers}';
                      _dirty = true;
                    })
                : null,
          ),
          for (final row in _subs)
            _SubcontractorRow(
              key: ValueKey('gunluk-rapor-taseron-${row.sub.supplierId}'),
              row: row,
              onChanged: () => setState(() => _dirty = true),
              onRemove: () => setState(() {
                _subs.remove(row);
                row.dispose();
                _dirty = true;
              }),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('gunluk-rapor-taseron-ekle'),
              icon: const Icon(Icons.group_add_outlined, size: 18),
              label: const Text('Taşeron ekle'),
              onPressed: () => _addSubcontractor(r, user),
            ),
          ),
        ],
      ),
      AppFormSection(
        title: 'Rapor',
        children: [
          _TextArea(key: const ValueKey('gunluk-rapor-yapilan'), label: 'Yapılan işler', controller: _workDone, onChanged: _markDirty),
          _TextArea(key: const ValueKey('gunluk-rapor-sorunlar'), label: 'Sorunlar / gecikmeler', controller: _issues, onChanged: _markDirty),
          _TextArea(key: const ValueKey('gunluk-rapor-malzeme'), label: 'Gelen malzeme', controller: _materials, onChanged: _markDirty),
          _TextArea(key: const ValueKey('gunluk-rapor-notlar'), label: 'Notlar', controller: _notes, onChanged: _markDirty),
        ],
      ),
    ];
  }
}

/// Günün başlığı: önceki/sonraki gün okları, uzun tarih, durum.
class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.day,
    required this.canGoNext,
    required this.report,
    required this.onPrev,
    required this.onNext,
  });

  final DateTime day;
  final bool canGoNext;
  final DailyReport report;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final meta = <String>[
      if (r.isSubmitted && r.submittedByName.isNotEmpty) 'Gönderen: ${r.submittedByName}',
      if (r.isSubmitted && r.submittedAt != null) Formatters.hm(r.submittedAt),
      if (!r.isSubmitted && r.createdByName.isNotEmpty) 'Yazan: ${r.createdByName}',
    ].join(' · ');
    return Row(
      children: [
        IconButton(
          key: const ValueKey('gunluk-rapor-onceki-gun'),
          tooltip: 'Önceki gün',
          onPressed: onPrev,
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Column(
            children: [
              Text(Formatters.longDate(formatDay(day)), style: AppTypography.cardTitle, textAlign: TextAlign.center),
              const SizedBox(height: 2),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (r.exists) dailyReportStatusBadge(r.isSubmitted),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Flexible(child: Text(meta, style: AppTypography.helper, overflow: TextOverflow.ellipsis)),
                  ],
                ],
              ),
            ],
          ),
        ),
        IconButton(
          key: const ValueKey('gunluk-rapor-sonraki-gun'),
          tooltip: 'Sonraki gün',
          onPressed: canGoNext ? onNext : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

/// Kişi sayısı: − / sayı / + (şantiyede eldivenle de basılır).
class _CountField extends StatelessWidget {
  const _CountField({
    super.key,
    required this.label,
    required this.controller,
    required this.onChanged,
    this.helper,
    this.onUseHelper,
  });

  final String label;
  final TextEditingController controller;
  final VoidCallback onChanged;
  final String? helper;
  final VoidCallback? onUseHelper;

  void _step(int delta) {
    final next = ((int.tryParse(controller.text.trim()) ?? 0) + delta).clamp(0, 9999);
    controller.text = '$next';
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: AppTypography.body)),
            IconButton(tooltip: 'Azalt', onPressed: () => _step(-1), icon: const Icon(Icons.remove_circle_outline)),
            SizedBox(
              width: 56,
              child: TextField(
                controller: controller,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                decoration: const InputDecoration(isDense: true, hintText: '0'),
                onChanged: (_) => onChanged(),
              ),
            ),
            IconButton(tooltip: 'Artır', onPressed: () => _step(1), icon: const Icon(Icons.add_circle_outline)),
          ],
        ),
        if (helper != null)
          Row(
            children: [
              Flexible(child: Text(helper!, style: AppTypography.helper)),
              if (onUseHelper != null)
                TextButton(
                  key: const ValueKey('gunluk-rapor-puantaj-kullan'),
                  onPressed: onUseHelper,
                  child: const Text('Kullan'),
                ),
            ],
          ),
      ],
    );
  }
}

class _SubcontractorRow extends StatelessWidget {
  const _SubcontractorRow({super.key, required this.row, required this.onChanged, required this.onRemove});

  final _SubRow row;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final s = row.sub;
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.xs, AppSpacing.sm),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTypography.cardTitle),
                    if (s.specialty.isNotEmpty) Text(s.specialty, style: AppTypography.helper),
                  ],
                ),
              ),
              IconButton(tooltip: 'Rapordan çıkar', onPressed: onRemove, icon: const Icon(Icons.close, size: 18)),
            ],
          ),
          _CountField(label: 'Kişi', controller: row.workers, onChanged: onChanged),
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: TextField(
              controller: row.note,
              maxLength: 300,
              decoration: const InputDecoration(labelText: 'Ne yaptı?', isDense: true, counterText: ''),
              onChanged: (_) => onChanged(),
            ),
          ),
        ],
      ),
    );
  }
}

class _TextArea extends StatelessWidget {
  const _TextArea({super.key, required this.label, required this.controller, required this.onChanged});

  final String label;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      minLines: 2,
      maxLines: 8,
      maxLength: 4000,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(labelText: label, alignLabelWithHint: true, counterText: ''),
      onChanged: (_) => onChanged(),
    );
  }
}

/// Rapora taşeron ekleme: projenin taşeronları (sunucudan); tedarikçi
/// okuyabilen "Tüm taşeronlar"dan da seçer.
class _SubcontractorOptionsSheet extends StatelessWidget {
  const _SubcontractorOptionsSheet({required this.options, this.onBrowse});

  final List<DailyReportSubcontractor> options;
  final VoidCallback? onBrowse;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Taşeron Ekle', style: AppTypography.sectionTitle),
          const SizedBox(height: AppSpacing.sm),
          if (options.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Text(
                'Bu projeye bağlı başka taşeron yok. Taşeronu projenin Taşeron Ödemeleri bölümünden ekleyebilirsin.',
                style: AppTypography.helper,
              ),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final o in options)
                    ListTile(
                      key: ValueKey('gunluk-rapor-secenek-${o.supplierId}'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.engineering_outlined),
                      title: Text(o.name),
                      subtitle: o.specialty.isEmpty ? null : Text(o.specialty),
                      onTap: () => Navigator.of(context).pop(o),
                    ),
                ],
              ),
            ),
          if (onBrowse != null)
            TextButton.icon(
              key: const ValueKey('gunluk-rapor-tum-taseronlar'),
              onPressed: onBrowse,
              icon: const Icon(Icons.search),
              label: const Text('Tüm taşeronlar'),
            ),
        ],
      ),
    );
  }
}

/// Okuma görünümü (yazma izni yok, proje kapalı).
class _ReadOnlyReport extends StatelessWidget {
  const _ReadOnlyReport({required this.report});

  final DailyReport report;

  @override
  Widget build(BuildContext context) {
    final r = report;
    final weather = [
      kDailyReportWeathers[r.weather] ?? '',
      if (r.temperatureC != null) '${r.temperatureC}°C',
    ].where((v) => v.isNotEmpty).join(' · ');
    Widget block(String title, String text) => Padding(
          padding: const EdgeInsets.only(top: AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTypography.helper),
              const SizedBox(height: 2),
              Text(text, style: AppTypography.body),
            ],
          ),
        );
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (weather.isNotEmpty)
            Row(
              children: [
                Icon(dailyReportWeatherIcon(r.weather), size: 18, color: AppColors.textMuted),
                const SizedBox(width: AppSpacing.xs),
                Text(weather, style: AppTypography.body),
              ],
            ),
          block(
            'Sahadaki ekip',
            'Kendi ekibimiz ${r.ownWorkers} · Taşeronlar ${r.subcontractorWorkers} · Toplam ${r.totalWorkers} kişi',
          ),
          for (final s in r.subcontractors)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '• ${s.name}: ${s.workers} kişi${s.workNote.isEmpty ? '' : ' — ${s.workNote}'}',
                style: AppTypography.metadata,
              ),
            ),
          if (r.workDone.isNotEmpty) block('Yapılan işler', r.workDone),
          if (r.issues.isNotEmpty) block('Sorunlar / gecikmeler', r.issues),
          if (r.materials.isNotEmpty) block('Gelen malzeme', r.materials),
          if (r.notes.isNotEmpty) block('Notlar', r.notes),
        ],
      ),
    );
  }
}

/// Sunucudan gelen günün verileri: tamamlanan görevler ve fotoğraflar.
class _AutoSection extends ConsumerWidget {
  const _AutoSection({required this.projectId, required this.report, required this.onPhotoDeleted});

  final String projectId;
  final DailyReport report;
  final VoidCallback onPhotoDeleted;

  /// Günün fotoğrafları Dokümanlar'daki galeride açılır (aynı hareketler,
  /// paylaş/sil). Raporun fotoğraf satırında yalnızca kimlik, aşama ve
  /// açıklama var; tarih zaten raporun günü.
  void _openGallery(BuildContext context, WidgetRef ref, int index) {
    final photos = [
      for (final p in report.photos)
        ProjectPhoto(
          id: p.id,
          originalName: '',
          mimeType: '',
          sizeBytes: 0,
          stage: p.stage,
          description: p.description,
          createdAt: '',
        ),
    ];
    showProjectPhotoGallery(
      context,
      projectId: projectId,
      photos: photos,
      initialIndex: index,
      canDelete: ref.read(authControllerProvider).valueOrNull.can(kProjectOpsManagePermission),
      onDeleted: (_) => onPhotoDeleted(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = report;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('O Gün Tamamlanan Görevler (${r.completedTasks.length})', style: AppTypography.sectionTitle),
        const SizedBox(height: AppSpacing.sm),
        if (r.completedTasks.isEmpty)
          const Text('Bu gün tamamlanan görev yok.', style: AppTypography.helper)
        else
          for (final t in r.completedTasks)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.check_circle_outline, size: 18, color: AppColors.success),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      [t.title, if (t.assignedName.isNotEmpty) t.assignedName].join(' · '),
                      style: AppTypography.body,
                    ),
                  ),
                ],
              ),
            ),
        const SizedBox(height: AppSpacing.lg),
        Text('O Gün Çekilen Fotoğraflar (${r.photos.length})', style: AppTypography.sectionTitle),
        const SizedBox(height: AppSpacing.xs),
        const Text(
          'Fotoğraflar Dokümanlar > Dosyalar\'dan eklenir; o gün yüklenenler rapora ve PDF\'e kendiliğinden girer.',
          style: AppTypography.helper,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (r.photos.isNotEmpty)
          SizedBox(
            height: 88,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: r.photos.length,
              separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
              itemBuilder: (context, i) => _PhotoThumb(
                key: ValueKey('gunluk-rapor-foto-${r.photos[i].id}'),
                projectId: projectId,
                photoId: r.photos[i].id,
                onTap: () => _openGallery(context, ref, i),
              ),
            ),
          ),
      ],
    );
  }
}

class _PhotoThumb extends ConsumerWidget {
  const _PhotoThumb({super.key, required this.projectId, required this.photoId, required this.onTap});

  final String projectId;
  final String photoId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(projectPhotoBytesProvider((projectId: projectId, photoId: photoId)));
    final dpr = MediaQuery.devicePixelRatioOf(context);
    const placeholder = ColoredBox(
      color: AppColors.background,
      child: Icon(Icons.broken_image_outlined, color: AppColors.textMuted),
    );
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.control),
        child: SizedBox(
          width: 88,
          height: 88,
          child: bytes.when(
            data: (b) => Image.memory(
              b,
              fit: BoxFit.cover,
              cacheWidth: (88 * dpr).ceil(),
              errorBuilder: (_, _, _) => placeholder,
            ),
            loading: () => const ColoredBox(
              color: AppColors.background,
              child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            ),
            error: (_, _) => placeholder,
          ),
        ),
      ),
    );
  }
}
