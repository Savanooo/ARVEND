import 'package:flutter/material.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../domain/price_change.dart';

/// Zam Geçmişi filtreleri (web PriceChangeFilters formu): kaynak, neden,
/// yön, sıralama, kategori, ürün adı. Dönem, ekrandaki dönem çiplerindedir.
/// "Uygula" yeni parametreleri, "Filtreleri sıfırla" varsayılanları döner;
/// kapatılırsa null.
Future<ZamlarParams?> showPriceChangesFilterSheet(
  BuildContext context, {
  required ZamlarParams params,
  required List<({String code, String name})> sources,
  required List<String> categories,
}) {
  return showModalBottomSheet<ZamlarParams>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => PriceChangesFilterSheet(params: params, sources: sources, categories: categories),
  );
}

class PriceChangesFilterSheet extends StatefulWidget {
  const PriceChangesFilterSheet({super.key, required this.params, required this.sources, required this.categories});

  final ZamlarParams params;
  final List<({String code, String name})> sources;
  final List<String> categories;

  @override
  State<PriceChangesFilterSheet> createState() => _PriceChangesFilterSheetState();
}

class _PriceChangesFilterSheetState extends State<PriceChangesFilterSheet> {
  late String _source = widget.params.source;
  late String _reason = widget.params.reason;
  late String _direction = widget.params.direction;
  late String _sort = widget.params.sort;
  late String _category = widget.params.category;
  late final TextEditingController _q = TextEditingController(text: widget.params.q);

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  void _apply() {
    Navigator.of(context).pop(
      applyFilters(
        widget.params,
        source: _source,
        reason: _reason,
        direction: _direction,
        category: _category,
        q: _q.text,
        sort: _sort,
      ),
    );
  }

  static String _fold(String s) => s.replaceAll('I', 'ı').replaceAll('İ', 'i').toLowerCase();

  @override
  Widget build(BuildContext context) {
    // Bilinmeyen bir kaynak kodu (ör. elle açılmış rota) açılır listeyi
    // bozmasın: seçeneklere eklenir.
    final sourceOptions = [
      ...widget.sources,
      if (_source.isNotEmpty && !widget.sources.any((s) => s.code == _source)) (code: _source, name: _source),
    ];
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.xl,
        right: AppSpacing.xl,
        top: AppSpacing.xl,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Filtreler', style: AppTypography.pageTitle.copyWith(fontSize: 17)),
            const SizedBox(height: AppSpacing.lg),
            DropdownButtonFormField<String>(
              initialValue: _source,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Kaynak'),
              items: [
                const DropdownMenuItem(value: '', child: Text('Tüm kaynaklar')),
                for (final s in sourceOptions) DropdownMenuItem(value: s.code, child: Text(s.name)),
              ],
              onChanged: (v) => setState(() => _source = v ?? ''),
            ),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<String>(
              initialValue: _reason,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Neden'),
              items: [for (final (value, label) in kReasonOptions) DropdownMenuItem(value: value, child: Text(label))],
              onChanged: (v) => setState(() => _reason = v ?? ZamlarParams.defaults.reason),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _direction,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Yön'),
                    items: [
                      for (final (value, label) in kDirectionOptions) DropdownMenuItem(value: value, child: Text(label)),
                    ],
                    onChanged: (v) => setState(() => _direction = v ?? ZamlarParams.defaults.direction),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _sort,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Sıralama'),
                    items: [
                      for (final (value, label) in kSortOptions)
                        DropdownMenuItem(value: value, child: Text(label, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) => setState(() => _sort = v ?? ZamlarParams.defaults.sort),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Autocomplete<String>(
              initialValue: TextEditingValue(text: _category),
              optionsBuilder: (value) {
                final text = _fold(value.text.trim());
                if (text.isEmpty) return widget.categories;
                return widget.categories.where((c) => _fold(c).contains(text));
              },
              onSelected: (v) => _category = v,
              fieldViewBuilder: (context, controller, focusNode, onSubmit) => TextField(
                controller: controller,
                focusNode: focusNode,
                maxLength: kMaxFilterText,
                decoration: const InputDecoration(
                  labelText: 'Kategori',
                  hintText: 'Tüm kategoriler',
                  counterText: '',
                ),
                onChanged: (v) => _category = v,
                onSubmitted: (_) => onSubmit(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _q,
              maxLength: kMaxFilterText,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                labelText: 'Ürün adı',
                hintText: 'Ürün adında ara…',
                prefixIcon: Icon(Icons.search),
                counterText: '',
              ),
              onSubmitted: (_) => _apply(),
            ),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              'Kaynak ve neden özeti de süzer; yön, kategori, arama ve sıralama yalnızca listeye uygulanır.',
              style: AppTypography.helper,
            ),
            const SizedBox(height: AppSpacing.lg),
            PrimaryButton(label: 'Uygula', onPressed: _apply),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: () => Navigator.of(context).pop(ZamlarParams.defaults),
              child: const Text('Filtreleri sıfırla'),
            ),
          ],
        ),
      ),
    );
  }
}
