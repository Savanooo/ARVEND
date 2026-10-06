import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/unsaved_changes_scope.dart';
import '../data/cost_codes_providers.dart';
import '../domain/cost_code.dart';
import 'widgets/cost_code_ui.dart';
import '../../../core/widgets/app_sheet.dart';

/// Yeni/düzenle formunu alt sayfa olarak açar; kaydedilen kodu döner
/// (vazgeçilirse null). [categories] mevcut kategori adlarıdır (hızlı
/// seçim çipleri -- aynı kategori farklı yazılıp gruplar bölünmesin).
/// Yalnızca `organization.cost_codes.manage` sahibine gösterilen
/// düğmelerden çağrılır.
Future<OrganizationCostCode?> showCostCodeFormSheet(
  BuildContext context, {
  OrganizationCostCode? existing,
  List<String> categories = const [],
}) {
  return showAppSheet<OrganizationCostCode>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => CostCodeFormSheet(existing: existing, categories: categories),
  );
}

/// Web `CostCodesManager` modalının alanları: Kod* (düzenlemede kilitli --
/// backend `Update` kodu hiç yazmaz), Ad*, Kategori, Açıklama. Uzunluk
/// sınırları veritabanı sütunlarıyla (migration 0035) aynıdır.
class CostCodeFormSheet extends ConsumerStatefulWidget {
  const CostCodeFormSheet({super.key, this.existing, this.categories = const []});

  final OrganizationCostCode? existing;
  final List<String> categories;

  bool get isEdit => existing != null;

  @override
  ConsumerState<CostCodeFormSheet> createState() => _CostCodeFormSheetState();
}

class _CostCodeFormSheetState extends ConsumerState<CostCodeFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _code;
  late final TextEditingController _name;
  late final TextEditingController _category;
  late final TextEditingController _description;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final c = widget.existing;
    _code = TextEditingController(text: c?.code ?? '');
    _name = TextEditingController(text: c?.name ?? '');
    _category = TextEditingController(text: c?.category ?? '');
    _description = TextEditingController(text: c?.description ?? '');
    _category.addListener(_onCategoryChanged);
  }

  void _onCategoryChanged() => setState(() {});

  @override
  void dispose() {
    _category.removeListener(_onCategoryChanged);
    _code.dispose();
    _name.dispose();
    _category.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = _category.text.trim();
    return UnsavedChangesScope(
      busy: _submitting,
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
                Text(
                  widget.isEdit ? 'Maliyet Kodunu Düzenle' : 'Yeni Maliyet Kodu',
                  style: AppTypography.pageTitle.copyWith(fontSize: 17),
                ),
                const SizedBox(height: AppSpacing.lg),
                AppFormSection(
                  title: 'Kod Bilgileri',
                  children: [
                    TextFormField(
                      key: const ValueKey('cost-code-code'),
                      controller: _code,
                      enabled: !widget.isEdit,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [LengthLimitingTextInputFormatter(30)],
                      decoration: InputDecoration(
                        labelText: 'Kod *',
                        hintText: 'ör. MLZ-001',
                        helperText: widget.isEdit
                            ? 'Kod oluşturulduktan sonra değiştirilemez (geçmiş kayıtlarla bağlantısını korumak için).'
                            : null,
                        helperMaxLines: 3,
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Maliyet kodu zorunludur' : null,
                    ),
                    TextFormField(
                      key: const ValueKey('cost-code-name'),
                      controller: _name,
                      inputFormatters: [LengthLimitingTextInputFormatter(150)],
                      decoration: const InputDecoration(labelText: 'Ad *', hintText: 'ör. Hazır Beton'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Maliyet kodu adı zorunludur' : null,
                    ),
                  ],
                ),
                AppFormSection(
                  title: 'Sınıflandırma',
                  children: [
                    TextFormField(
                      key: const ValueKey('cost-code-category'),
                      controller: _category,
                      inputFormatters: [LengthLimitingTextInputFormatter(60)],
                      decoration: const InputDecoration(
                        labelText: 'Kategori',
                        hintText: 'ör. Malzeme, İşçilik, Ekipman, Taşeron',
                      ),
                    ),
                    if (widget.categories.isNotEmpty)
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.xs,
                        children: [
                          for (final cat in widget.categories)
                            ChoiceChip(
                              label: Text(cat),
                              selected: cat == current,
                              onSelected: (_) => _category.text = cat,
                            ),
                        ],
                      ),
                    TextFormField(
                      controller: _description,
                      minLines: 2,
                      maxLines: 4,
                      inputFormatters: [LengthLimitingTextInputFormatter(300)],
                      decoration: const InputDecoration(labelText: 'Açıklama', alignLabelWithHint: true),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  Text(_error!, style: AppTypography.error),
                  const SizedBox(height: AppSpacing.md),
                ],
                PrimaryButton(label: 'Kaydet', loading: _submitting, onPressed: _submit),
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
    final input = CostCodeInput(
      name: _name.text.trim(),
      category: _category.text.trim(),
      description: _description.text.trim(),
    );
    setState(() {
      _submitting = true;
      _error = null;
    });
    // Kayıt sürerken sayfa kapanmış olsa bile altta açık kalan liste/detay
    // tazelensin: kapsayıcı ilk await'ten ÖNCE alınır.
    final container = ProviderScope.containerOf(context, listen: false);
    final existing = widget.existing;
    final code = _code.text.trim();
    try {
      final repo = container.read(costCodesRepositoryProvider);
      final saved = existing != null
          ? await repo.update(existing.id, input)
          : await repo.create(code: code, input: input);
      container.invalidate(costCodesListProvider);
      if (existing != null) container.invalidate(costCodeDetailProvider(existing.id));
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) setState(() => _error = costCodeErrorText(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}
