import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../offers/domain/offer.dart';
import '../data/calc_providers.dart';
import '../domain/calc.dart';

/// Metraj Hesaplama: Grup seç -> Kategori seç -> Ölçü gir -> Hesapla ->
/// Malzeme sonucu -> Teklife ekle. Motor mobilde YOK - yalnızca
/// POST /calculations/run çağrılır, backend'in döndürdüğü sonuç aynen
/// gösterilir (bkz. mobile/API_CONTRACT.md#calculations).
class MetrajScreen extends ConsumerStatefulWidget {
  const MetrajScreen({super.key});

  @override
  ConsumerState<MetrajScreen> createState() => _MetrajScreenState();
}

class _MetrajScreenState extends ConsumerState<MetrajScreen> {
  CalcGroupWithCategories? _group;
  CalcCategory? _category;
  bool _useAreaDirectly = true;
  final _areaController = TextEditingController();
  final _widthController = TextEditingController();
  final _heightController = TextEditingController();
  final _perimeterController = TextEditingController();
  final _pitchController = TextEditingController();

  CalcRunResult? _result;
  bool _calculating = false;
  String? _error;
  final Set<String> _selectedForOffer = {};

  @override
  void dispose() {
    _areaController.dispose();
    _widthController.dispose();
    _heightController.dispose();
    _perimeterController.dispose();
    _pitchController.dispose();
    super.dispose();
  }

  Future<void> _calculate() async {
    if (_category == null) return;
    setState(() {
      _calculating = true;
      _error = null;
    });
    try {
      final result = await ref.read(calcRepositoryProvider).run(
            categoryId: _category!.id,
            area: _useAreaDirectly ? _nonEmpty(_areaController.text) : null,
            width: _useAreaDirectly ? null : _nonEmpty(_widthController.text),
            height: _useAreaDirectly ? null : _nonEmpty(_heightController.text),
            perimeter: _nonEmpty(_perimeterController.text),
            pitchDeg: _nonEmpty(_pitchController.text),
          );
      setState(() {
        _result = result;
        _selectedForOffer
          ..clear()
          ..addAll(result.items.map((e) => e.recipeItemId));
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _calculating = false);
    }
  }

  String? _nonEmpty(String v) => v.trim().isEmpty ? null : v.trim().replaceAll(',', '.');

  void _addToOffer() {
    final result = _result;
    if (result == null) return;
    final items = result.items
        .where((i) => _selectedForOffer.contains(i.recipeItemId))
        .map((i) => OfferItem(
              id: '',
              productId: i.productId,
              productName: i.materialName,
              quantity: double.tryParse(i.quantity) ?? 0,
              unitPrice: double.tryParse(i.unitPrice) ?? 0,
              lineTotal: 0,
              unit: i.unit,
              sectionLabel: result.categoryName,
              calcCategoryId: result.categoryId,
              calcSnapshot: {
                'recipe_item_id': i.recipeItemId,
                'category_id': result.categoryId,
                'category_name': result.categoryName,
                'footprint_area': result.footprintArea,
                'effective_area': result.effectiveArea,
                'perimeter': result.perimeter,
                'calculation_type': i.calculationType,
                'factor': i.factor,
                'waste_percent': i.wastePercent,
                'rounding_type': i.roundingType,
                'price_at_calc': i.unitPrice,
              },
            ))
        .toList();
    if (items.isEmpty) return;
    context.push('/teklifler/yeni', extra: items);
  }

  @override
  Widget build(BuildContext context) {
    final catalogAsync = ref.watch(calcCatalogProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Metraj Hesaplama')),
      body: AsyncStateView(
        value: catalogAsync,
        onRetry: () async => ref.invalidate(calcCatalogProvider),
        data: (context, groups) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            DropdownButtonFormField<CalcGroupWithCategories>(
              initialValue: _group,
              decoration: const InputDecoration(labelText: 'Grup'),
              items: groups.map((g) => DropdownMenuItem(value: g, child: Text(g.name))).toList(),
              onChanged: (g) => setState(() {
                _group = g;
                _category = null;
                _result = null;
              }),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<CalcCategory>(
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'Hesaplama Türü (Kategori)'),
              items: (_group?.categories ?? [])
                  .map((c) => DropdownMenuItem(value: c, child: Text(c.name)))
                  .toList(),
              onChanged: _group == null
                  ? null
                  : (c) => setState(() {
                        _category = c;
                        _result = null;
                      }),
            ),
            if (_category != null) ...[
              const SizedBox(height: 20),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Doğrudan Alan')),
                  ButtonSegment(value: false, label: Text('En × Boy')),
                ],
                selected: {_useAreaDirectly},
                onSelectionChanged: (s) => setState(() => _useAreaDirectly = s.first),
              ),
              const SizedBox(height: 12),
              if (_useAreaDirectly)
                TextField(
                  controller: _areaController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Alan (m²)'),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _widthController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'En (m)'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _heightController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Boy (m)'),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _perimeterController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Çevre (m) — opsiyonel',
                  helperText: 'Boş bırakılırsa En×Boy\'dan hesaplanır (yalnızca En×Boy modunda)',
                ),
              ),
              if (_group?.looksLikeRoof ?? false) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _pitchController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Çatı Eğimi (derece) — opsiyonel'),
                ),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _calculating ? null : _calculate,
                child: _calculating
                    ? const SizedBox(
                        width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                    : const Text('Hesapla'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: AppColors.danger)),
              ],
            ],
            if (_result != null) _ResultSection(
              result: _result!,
              selected: _selectedForOffer,
              onToggle: (id, v) => setState(() {
                if (v) {
                  _selectedForOffer.add(id);
                } else {
                  _selectedForOffer.remove(id);
                }
              }),
              onAddToOffer: _addToOffer,
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultSection extends StatelessWidget {
  const _ResultSection({
    required this.result,
    required this.selected,
    required this.onToggle,
    required this.onAddToOffer,
  });

  final CalcRunResult result;
  final Set<String> selected;
  final void Function(String id, bool value) onToggle;
  final VoidCallback onAddToOffer;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Card(
          color: AppColors.background,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Etkin Alan: ${Formatters.quantityFromString(result.effectiveArea)} m²'),
                if (result.perimeter != null)
                  Text('Çevre: ${Formatters.quantityFromString(result.perimeter!)} m'),
              ],
            ),
          ),
        ),
        if (result.warnings.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              children: result.warnings
                  .map((w) => Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.warning_amber_rounded, color: AppColors.warning, size: 18),
                            const SizedBox(width: 8),
                            Expanded(child: Text(w.message, style: const TextStyle(fontSize: 12.5))),
                          ],
                        ),
                      ))
                  .toList(),
            ),
          ),
        const SizedBox(height: 8),
        const Text('Malzeme Listesi', style: TextStyle(fontWeight: FontWeight.w700)),
        ...result.items.map((item) => Card(
              margin: const EdgeInsets.only(top: 6),
              child: CheckboxListTile(
                value: selected.contains(item.recipeItemId),
                onChanged: (v) => onToggle(item.recipeItemId, v ?? false),
                title: Text(item.materialName),
                subtitle: Text(
                  '${Formatters.quantityFromString(item.quantity)} ${item.unit} × '
                  '${Formatters.moneyFromString(item.unitPrice)}',
                ),
                secondary: SizedBox(
                  width: 84,
                  child: Text(
                    Formatters.moneyFromString(item.lineTotal),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            )),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Toplam', style: TextStyle(fontWeight: FontWeight.w700)),
                Text(Formatters.moneyFromString(result.totalCost),
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: selected.isEmpty ? null : onAddToOffer,
          icon: const Icon(Icons.add_shopping_cart_outlined),
          label: Text('Teklife Ekle (${selected.length})'),
        ),
      ],
    );
  }
}
