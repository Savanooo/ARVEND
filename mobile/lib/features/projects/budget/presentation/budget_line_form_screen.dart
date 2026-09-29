import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/auth/auth_controller.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/errors/api_exception.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/app_typography.dart';
import '../../../../core/widgets/access_notices.dart';
import '../../../../core/widgets/app_buttons.dart';
import '../../../../core/widgets/app_form_section.dart';
import '../../../../core/widgets/app_page_scaffold.dart';
import '../../../../core/widgets/async_state_view.dart';
import '../../../../core/widgets/unsaved_changes_scope.dart';
import '../data/budget_providers.dart';
import '../domain/budget.dart';
import 'widgets/budget_ui.dart';

/// Bütçe kalemi ekle/düzenle (web `BudgetTab` modalı): WBS (opsiyonel),
/// Maliyet Kodu*, Açıklama*, Miktar, Birim, Birim Fiyat, Orijinal Tutar.
/// Miktar VE birim fiyat birlikte girilirse tutarı sunucu hesaplar (alan
/// kilitlenir). Yalnızca TASLAK bütçede; baseline sonrası sunucu 409 döner
/// (mesaj gösterilir, ekran tazelenir). `projects.budget.manage` ister.
/// Kaydedilirse `true` ile kapanır.
class BudgetLineFormScreen extends ConsumerStatefulWidget {
  const BudgetLineFormScreen({super.key, required this.projectId, this.lineId});

  final String projectId;
  final String? lineId;

  bool get isEdit => lineId != null;

  @override
  ConsumerState<BudgetLineFormScreen> createState() => _BudgetLineFormScreenState();
}

class _BudgetLineFormScreenState extends ConsumerState<BudgetLineFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _quantity = TextEditingController();
  final _unit = TextEditingController();
  final _unitCost = TextEditingController();
  final _amount = TextEditingController();
  String? _wbsNodeId;
  String? _costCodeId;
  BudgetLine? _existing;
  bool _initialized = false;
  bool _submitting = false;
  bool _dirty = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final c in [_quantity, _unitCost]) {
      c.addListener(_onComputedInputsChanged);
    }
  }

  void _onComputedInputsChanged() => setState(() {});

  @override
  void dispose() {
    for (final c in [_description, _quantity, _unit, _unitCost, _amount]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _serverComputes =>
      parseTrDecimal(_quantity.text, maxFractionDigits: 4).value != null &&
      parseTrDecimal(_unitCost.text).value != null;

  void _initFrom(BudgetLine? line) {
    if (_initialized) return;
    _initialized = true;
    _existing = line;
    if (line == null) return;
    _wbsNodeId = line.wbsNodeId;
    _costCodeId = line.costCodeId;
    _description.text = line.description;
    _quantity.text = formatTrDecimalInput(line.quantity, maxFractionDigits: 4);
    _unit.text = line.unit;
    _unitCost.text = formatTrDecimalInput(line.unitCost);
    _amount.text = formatTrDecimalInput(line.originalAmount);
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final quantity = parseTrDecimal(_quantity.text, maxFractionDigits: 4).value;
    final unitCost = parseTrDecimal(_unitCost.text).value;
    final input = BudgetLineInput(
      wbsNodeId: _wbsNodeId,
      costCodeId: _costCodeId!,
      description: _description.text.trim(),
      quantity: quantity,
      unit: _unit.text.trim(),
      unitCost: unitCost,
      originalAmount: parseTrDecimal(_amount.text).value ?? 0,
      notes: _existing?.notes ?? '',
    );
    setState(() {
      _submitting = true;
      _error = null;
    });
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final repo = container.read(budgetRepositoryProvider);
      if (widget.lineId == null) {
        await repo.createBudgetLine(widget.projectId, input);
      } else {
        await repo.updateBudgetLine(widget.projectId, widget.lineId!, input);
      }
      invalidateBudgetModule(container.invalidate, widget.projectId);
      if (mounted) context.pop(true);
    } catch (e) {
      // 409: bütçe bu arada baseline alındı -- ekranlar güncel duruma döner.
      if (isBudgetConflict(e)) invalidateBudgetModule(container.invalidate, widget.projectId);
      if (mounted) setState(() => _error = budgetErrorText(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = Text(widget.isEdit ? 'Bütçe Kalemini Düzenle' : 'Yeni Bütçe Kalemi');
    final auth = ref.watch(authControllerProvider);
    final user = auth.valueOrNull;
    if (isAuthPending(auth)) return AppPageScaffold(title: title, body: const LoadingState());
    if (!user.can(kBudgetManagePermission)) {
      return AppPageScaffold(
        title: title,
        body: const BudgetNoAccessView(
          message:
              'Bütçe kalemi eklemek veya düzenlemek için rolünde "Proje bütçesini oluşturma/onaylama/revize '
              'etme" izni olmalı.',
        ),
      );
    }

    final budgetAsync = ref.watch(projectBudgetProvider(widget.projectId));
    final linesAsync = widget.isEdit ? ref.watch(budgetLinesProvider(widget.projectId)) : null;
    final wbsAsync = ref.watch(budgetWbsNodesProvider(widget.projectId));
    final costCodesAsync = ref.watch(budgetCostCodesProvider);
    final project = ref.watch(budgetProjectProvider(widget.projectId)).valueOrNull;

    final loadError = budgetAsync.error ?? linesAsync?.error;
    if (loadError != null) {
      return AppPageScaffold(
        title: title,
        body: isBudgetForbidden(loadError)
            ? const BudgetNoAccessView(message: kBudgetNoAccessText)
            : ErrorState(
                error: loadError,
                onRetry: () async => invalidateBudgetModule(ref.invalidate, widget.projectId),
              ),
      );
    }
    // Seçiciler (WBS/maliyet kodu) veri gelmeden kurulmaz: DropdownButtonFormField
    // başlangıç değerini yalnızca ilk kurulumda okur, düzenlenen kalemin
    // seçimi kaybolmasın.
    bool pending(AsyncValue<Object?> v) => !v.hasValue && !v.hasError;
    if (!budgetAsync.hasValue ||
        (linesAsync != null && !linesAsync.hasValue) ||
        pending(wbsAsync) ||
        pending(costCodesAsync)) {
      return AppPageScaffold(title: title, body: const LoadingState());
    }
    final budget = budgetAsync.value;
    BudgetLine? line;
    if (widget.isEdit) {
      line = linesAsync!.value!.where((l) => l.id == widget.lineId).firstOrNull;
      if (line == null && !_initialized) {
        return AppPageScaffold(
          title: title,
          body: const EmptyStateView(message: 'Bütçe kalemi bulunamadı.', icon: Icons.search_off),
        );
      }
    }
    _initFrom(line);

    final locked = project != null && isProjectLocked(project.status);
    final blockedReason = budget == null
        ? 'Bu proje için henüz bir bütçe yok; önce bütçe oluştur.'
        : !budget.isDraft
        ? 'Bütçe baseline alındı — kalemler artık yalnızca Bütçe Revizyonu ile değiştirilebilir.'
        : locked
        ? kProjectLockedText
        : null;
    final currency = budget?.currency ?? project?.currency ?? 'TRY';

    return UnsavedChangesScope(
      busy: _submitting,
      dirty: _dirty && blockedReason == null,
      child: AppPageScaffold(
        title: title,
        body: blockedReason != null
            ? ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  if (_error != null) ...[
                    Text(_error!, style: AppTypography.error),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  ReadOnlyNotice(blockedReason),
                ],
              )
            : Form(
                key: _formKey,
                onChanged: () {
                  if (!_dirty) setState(() => _dirty = true);
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
                  children: [
                    AppFormSection(
                      title: 'Sınıflandırma',
                      children: [_wbsField(wbsAsync), _costCodeField(costCodesAsync)],
                    ),
                    AppFormSection(
                      title: 'Kalem Bilgileri',
                      children: [
                        TextFormField(
                          key: const ValueKey('line-description'),
                          controller: _description,
                          minLines: 1,
                          maxLines: 3,
                          inputFormatters: [LengthLimitingTextInputFormatter(300)],
                          decoration: const InputDecoration(labelText: 'Açıklama *'),
                          validator: (v) =>
                              (v == null || v.trim().isEmpty) ? 'Bütçe kalemi açıklaması zorunludur' : null,
                        ),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 3,
                              child: BudgetNumberField(
                                fieldKey: const ValueKey('line-quantity'),
                                controller: _quantity,
                                label: 'Miktar',
                                maxFractionDigits: 4,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                key: const ValueKey('line-unit'),
                                controller: _unit,
                                inputFormatters: [LengthLimitingTextInputFormatter(30)],
                                decoration: const InputDecoration(labelText: 'Birim', hintText: 'm³'),
                              ),
                            ),
                          ],
                        ),
                        BudgetNumberField(
                          fieldKey: const ValueKey('line-unit-cost'),
                          controller: _unitCost,
                          label: 'Birim Fiyat ($currency)',
                        ),
                      ],
                    ),
                    AppFormSection(
                      title: 'Tutar',
                      children: [
                        BudgetNumberField(
                          fieldKey: const ValueKey('line-amount'),
                          controller: _amount,
                          label: 'Orijinal Tutar ($currency)',
                          enabled: !_serverComputes,
                          helperText: _serverComputes
                              ? 'Miktar ve birim fiyat girildiği için tutar sunucuda otomatik hesaplanır.'
                              : 'Miktar ve birim fiyatın ikisi de girilirse bu alan yok sayılır, tutar otomatik '
                                    'hesaplanır.',
                        ),
                      ],
                    ),
                    if (_error != null) ...[
                      Text(_error!, style: AppTypography.error),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    PrimaryButton(
                      label: 'Kaydet',
                      loading: _submitting,
                      onPressed: costCodesAsync.hasError ? null : _submit,
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _wbsField(AsyncValue<List<WbsNode>> wbsAsync) {
    final nodes = wbsAsync.valueOrNull ?? const <WbsNode>[];
    // (değer, açılır listedeki girintili etiket, seçiliyken görünen etiket)
    final options = <(String?, String, String)>[
      (null, 'Yok', 'Yok'),
      for (final e in flattenWbsTree(nodes))
        if (e.node.isActive || e.node.id == _wbsNodeId)
          (
            e.node.id,
            '${'   ' * e.depth}${e.node.label}${e.node.isActive ? '' : ' (arşivlendi)'}',
            '${e.node.label}${e.node.isActive ? '' : ' (arşivlendi)'}',
          ),
    ];
    // Düzenlenen kalemin düğümü listede yoksa (ör. yüklenemedi) değer kaybolmasın.
    final existing = _existing;
    if (_wbsNodeId != null && !options.any((o) => o.$1 == _wbsNodeId) && existing != null) {
      final label = '${existing.wbsCode} — ${existing.wbsName}';
      options.add((_wbsNodeId, label, label));
    }
    Text text(String t) => Text(t, maxLines: 1, overflow: TextOverflow.ellipsis);
    return DropdownButtonFormField<String?>(
      key: const ValueKey('line-wbs'),
      initialValue: options.any((o) => o.$1 == _wbsNodeId) ? _wbsNodeId : null,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'WBS (opsiyonel)',
        helperText: wbsAsync.hasError ? 'WBS listesi yüklenemedi.' : null,
      ),
      items: [for (final o in options) DropdownMenuItem<String?>(value: o.$1, child: text(o.$2))],
      selectedItemBuilder: (_) => [for (final o in options) text(o.$3)],
      onChanged: (v) => setState(() {
        _wbsNodeId = v;
        _dirty = true;
      }),
    );
  }

  Widget _costCodeField(AsyncValue<List<OrgCostCode>> costCodesAsync) {
    if (costCodesAsync.hasError) {
      final e = costCodesAsync.error;
      return ReadOnlyNotice(
        e is ApiException && e.isForbidden
            ? kCostCodesForbiddenText
            : 'Maliyet kodları yüklenemedi: ${budgetErrorText(e!)}',
      );
    }
    final codes = costCodesAsync.valueOrNull ?? const <OrgCostCode>[];
    final items = <DropdownMenuItem<String>>[
      for (final c in codes)
        if (c.isActive || c.id == _costCodeId)
          DropdownMenuItem(
            value: c.id,
            child: Text(
              '${c.code} — ${c.name}${c.isActive ? '' : ' (arşivlendi)'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
    ];
    final existing = _existing;
    if (_costCodeId != null && !items.any((i) => i.value == _costCodeId) && existing != null) {
      items.add(
        DropdownMenuItem(
          value: _costCodeId,
          child: Text(existing.costCodeLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      );
    }
    return DropdownButtonFormField<String>(
      key: const ValueKey('line-cost-code'),
      initialValue: items.any((i) => i.value == _costCodeId) ? _costCodeId : null,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Maliyet Kodu *',
        hintText: costCodesAsync.isLoading ? 'Yükleniyor…' : 'Seç…',
      ),
      items: items,
      onChanged: (v) => setState(() {
        _costCodeId = v;
        _dirty = true;
      }),
      validator: (v) => v == null ? 'Maliyet kodu seç' : null,
    );
  }
}
