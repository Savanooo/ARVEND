import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_buttons.dart';
import '../../../core/widgets/app_form_section.dart';
import '../../../core/widgets/app_page_scaffold.dart';
import '../../../core/widgets/async_state_view.dart';
import '../data/products_providers.dart';
import '../domain/price_source.dart';
import '../domain/product.dart';
import 'products_paths.dart';
import 'widgets/products_common.dart';

/// Ürün ekle / düzenle (web NewProductForm + EditProductForm). Yalnızca
/// backend'in kabul ettiği alanlar vardır (name/unit/unit_price/
/// description/category). products.manage ister; izinsiz kullanıcı formu
/// hiç görmez (rota elle açılsa bile).
class ProductFormScreen extends ConsumerWidget {
  const ProductFormScreen({super.key, this.productId});

  /// null = yeni ürün.
  final String? productId;

  bool get isEdit => productId != null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppPageScaffold(
      title: Text(isEdit ? 'Ürünü Düzenle' : 'Yeni Ürün'),
      body: ProductsAccessGate(
        permission: ProductsPermissions.manage,
        deniedMessage: isEdit
            ? 'Bu ürünü yalnızca görüntüleyebilirsin; düzenlemek için rolünde "Ürün kataloğunu düzenleme" izni olmalı.'
            : 'Ürün eklemek için rolünde "Ürün kataloğunu düzenleme" izni olmalı.',
        child: isEdit ? _EditLoader(productId: productId!) : const _ProductForm(),
      ),
    );
  }
}

/// Düzenlemede ürün + fiyat kaynağı (ad/birim kilidi için) yüklenir. Kaynak
/// bilgisi alınamazsa kilit güvenli tarafta kalır (bağlı sayılır).
class _EditLoader extends ConsumerWidget {
  const _EditLoader({required this.productId});
  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final productAsync = ref.watch(productDetailProvider(productId));
    final sourcesAsync = ref.watch(priceSourcesProvider);
    return ProductsAsyncView(
      value: productAsync,
      onRetry: () async => ref.invalidate(productDetailProvider(productId)),
      data: (context, product) {
        if (!product.isManual && sourcesAsync.isLoading && !sourcesAsync.hasValue) return const LoadingState();
        final ps = findPriceSource(sourcesAsync.valueOrNull, product.source);
        return _ProductForm(
          existing: product,
          sourceLink: sourceLinkOf(product, ps),
          sourceName: product.isManual ? '' : sourceLabels(product.source, ps?.name).short,
        );
      },
    );
  }
}

class _ProductForm extends ConsumerStatefulWidget {
  const _ProductForm({this.existing, this.sourceLink = ProductSourceLink.none, this.sourceName = ''});

  final Product? existing;
  final ProductSourceLink sourceLink;
  final String sourceName;

  @override
  ConsumerState<_ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends ConsumerState<_ProductForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _unit;
  late final TextEditingController _price;
  late final TextEditingController _category;
  late final TextEditingController _description;
  bool _submitting = false;
  String? _error;

  bool get _isEdit => widget.existing != null;
  bool get _lockNameUnit => widget.sourceLink == ProductSourceLink.linked;

  /// Kaynağa bağlı ürünün fiyatını her tedarikçi güncellemesi (gece
  /// senkronu dahil) kaynak fiyat + kâr oranından yeniden yazar -- elle
  /// girilen fiyat uyarısız geri alınıyordu. Web formu da kilitli.
  bool get _lockPrice => widget.sourceLink == ProductSourceLink.linked;

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    _name = TextEditingController(text: p?.name ?? '');
    _unit = TextEditingController(text: p?.unit ?? 'adet');
    _price = TextEditingController(text: p == null ? '' : formatPriceInput(p.unitPrice));
    _category = TextEditingController(text: p?.category ?? '');
    _description = TextEditingController(text: p?.description ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _price.dispose();
    _category.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final existing = widget.existing;
    final input = ProductInput(
      // Kaynağa bağlı üründe ad/birim/fiyat kilitlidir: mevcut değerler aynen gider.
      name: _lockNameUnit ? existing!.name : _name.text.trim(),
      unit: _lockNameUnit ? existing!.unit : _unit.text.trim(),
      unitPrice: _lockPrice ? existing!.unitPrice : parsePriceInput(_price.text).value!,
      category: _category.text.trim(),
      description: _description.text.trim(),
    );
    setState(() {
      _submitting = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    // Kayıt sürerken ekran kapanmış olabilir: önbellekler yine tazelensin.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final repo = ref.read(productsRepositoryProvider);
      if (existing != null) {
        await repo.update(existing.id, input);
      } else {
        await repo.create(input);
      }
      invalidateProductData(container.invalidate);
      if (!mounted) return;
      messenger?.showSnackBar(SnackBar(content: Text(_isEdit ? 'Kaydedildi.' : 'Ürün eklendi.')));
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(ProductsPaths.list);
      }
    } catch (e) {
      if (mounted) setState(() => _error = productsActionError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final src = widget.sourceName;
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          if (widget.sourceLink != ProductSourceLink.none) ...[
            ProductsNotice(
              tone: NoticeTone.info,
              text:
                  'Bu ürün $src listesinden geliyor. Fiyatı ve kategorisi her $src güncellemesinde yeniden yazılır; '
                  '${_lockPrice ? 'burada yapılan kategori değişiklikleri' : 'burada yapılan fiyat ve kategori değişiklikleri'} '
                  'bir sonraki güncellemede kaybolur. Satış fiyatını kalıcı değiştirmek için Fiyat Kaynakları '
                  'ekranındaki kâr oranı ayarlarını kullan.',
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
          AppFormSection(
            title: 'Ürün Bilgileri',
            children: [
              TextFormField(
                controller: _name,
                enabled: !_lockNameUnit,
                textCapitalization: TextCapitalization.sentences,
                inputFormatters: [LengthLimitingTextInputFormatter(ProductFieldLimits.name)],
                decoration: const InputDecoration(labelText: 'Ürün Adı *'),
                validator: (v) => _lockNameUnit || (v ?? '').trim().isNotEmpty ? null : 'Ürün adı zorunludur',
              ),
              TextFormField(
                controller: _unit,
                enabled: !_lockNameUnit,
                inputFormatters: [LengthLimitingTextInputFormatter(ProductFieldLimits.unit)],
                decoration: const InputDecoration(labelText: 'Birim *', hintText: 'adet, m², kg…'),
                validator: (v) => _lockNameUnit || (v ?? '').trim().isNotEmpty ? null : 'Birim zorunludur',
              ),
              if (widget.sourceLink == ProductSourceLink.linked)
                Text(
                  'Ad ve birim $src listesinden gelir ve ürünü listeyle eşleştirmek için kullanılır, bu yüzden '
                  'değiştirilemez. Değişselerdi bir sonraki güncelleme $src ürününü yeni bir kayıt olarak ekler, bu '
                  'kayıt da fiyat almazdı. Farklı adla satmak için elle yeni ürün ekle.',
                  style: AppTypography.helper,
                ),
              if (widget.sourceLink == ProductSourceLink.missing)
                Text(
                  'Bu ürün son $src listesinde yok. Ad ve birim, $src listesindekiyle birebir aynı (büyük/küçük harf '
                  'dahil) olursa bir sonraki güncellemede yeniden eşleşir; farklı olursa $src ürünü ayrı bir kayıt '
                  'olarak eklenir.',
                  style: AppTypography.helper,
                ),
              TextFormField(
                key: const ValueKey('product-price'),
                controller: _price,
                enabled: !_lockPrice,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Birim Fiyat (TL) *', hintText: 'ör. 1250,50'),
                validator: (v) => _lockPrice ? null : parsePriceInput(v ?? '').error,
              ),
              if (_lockPrice) ...[
                Text(
                  'Birim fiyat $src listesindeki fiyata kâr oranı uygulanarak hesaplanır ve her $src güncellemesinde '
                  '(gece otomatik güncellemesi dahil) yeniden yazılır; elle girilen fiyat korunmazdı. Fiyatı '
                  'değiştirmek için $src kâr oranını (genel ya da kategori bazında) ayarla.',
                  key: const ValueKey('product-price-locked-hint'),
                  style: AppTypography.helper,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.percent, size: 18),
                    label: const Text('Kâr oranını ayarla'),
                    onPressed: () => context.push(ProductsPaths.sources),
                  ),
                ),
              ],
              TextFormField(
                controller: _category,
                inputFormatters: [LengthLimitingTextInputFormatter(ProductFieldLimits.category)],
                decoration: const InputDecoration(labelText: 'Kategori'),
              ),
              TextFormField(
                controller: _description,
                decoration: const InputDecoration(labelText: 'Açıklama'),
                maxLines: 3,
                minLines: 1,
              ),
            ],
          ),
          if (_error != null) ...[
            Text(_error!, style: AppTypography.error),
            const SizedBox(height: AppSpacing.md),
          ],
          PrimaryButton(
            label: _isEdit ? 'Kaydet' : 'Ürün Oluştur',
            loading: _submitting,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
