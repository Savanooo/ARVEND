import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../../products/data/products_providers.dart';
import '../../products/domain/price_source.dart';
import '../../products/domain/product.dart';
import '../domain/offer.dart' show currencyLabel;

/// Öneri araması bu kadar karakterden sonra başlar: tek harf tüm kataloğu
/// eşleştirir, isteği boşa harcar.
const kProductSuggestMinChars = 2;

/// Yazma duraklayınca bu kadar beklenir; her tuşa bir istek gitmez.
const kProductSuggestDebounce = Duration(milliseconds: 300);

/// Teklif kalemindeki "Ürün / Hizmet Adı" alanı + katalog önerileri.
///
/// Neden: alan düz metindi, kalem katalogla hiç bağlanmıyor, birim ve fiyat
/// elle yazılıyordu ("teklifte ürün adı yazınca ürün gelmiyor"). Web'deki
/// teklif formunun ürün listesinin (datalist) mobil karşılığı: seçilen ürün
/// kalemin adını, birimini, fiyatını ve product_id'sini doldurur (bunu
/// [onPicked] ile çağıran yapar); alanlar sonra yine düzenlenebilir.
///
/// Öneri seçmek ZORUNLU DEĞİL: eşleşme yoksa ya da çevrimdışıysa yazılan ad
/// bugünkü gibi serbest kalem olarak kalır; hiçbir şey kaydı engellemez.
/// [catalogEnabled] false ise (products.read yok) düz alandır ve hiç istek
/// atmaz -- izinsiz kullanıcı her harfte 403 almasın.
///
/// Öneriler alanın hemen altında, kartın içinde açılır (üstte duran bir
/// katman değil): küçük telefonda klavye açıkken de kaydırılarak görülür,
/// form kaydırılınca alandan kopmaz.
class OfferProductNameField extends ConsumerStatefulWidget {
  const OfferProductNameField({
    super.key,
    required this.controller,
    required this.label,
    required this.catalogEnabled,
    required this.onChanged,
    required this.onPicked,
    this.validator,
    this.offerCurrency = 'TRY',
  });

  final TextEditingController controller;
  final String label;
  final bool catalogEnabled;
  final ValueChanged<String> onChanged;
  final ValueChanged<Product> onPicked;
  final FormFieldValidator<String>? validator;

  /// Teklifin para birimi. Katalog fiyatları TL'dir ve seçimde çevrilmeden
  /// yazılır (web de böyle); teklif TL değilse önerilerin üstünde uyarı çıkar.
  final String offerCurrency;

  @override
  ConsumerState<OfferProductNameField> createState() => _OfferProductNameFieldState();
}

enum _Status { idle, loading, results, empty, offline, failed }

class _OfferProductNameFieldState extends ConsumerState<OfferProductNameField> {
  final _focus = FocusNode();
  Timer? _debounce;
  CancelToken? _inflight;

  /// Her aramanın sırası: geç dönen eski bir yanıt yenisinin üstüne yazmasın.
  int _seq = 0;
  _Status _status = _Status.idle;
  List<Product> _results = const [];
  int _total = 0;

  /// Seçilen ürünün adı: alan bu metni taşıdığı sürece yeniden aranmaz
  /// (seçimden hemen sonra aynı ürün tekrar önerilmesin).
  String? _pickedName;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _inflight?.cancel();
    _focus
      ..removeListener(_onFocusChange)
      ..dispose();
    super.dispose();
  }

  /// Kullanıcı başka bir alana geçince öneriler kapanır (kart boşuna uzun
  /// kalmasın); geri gelip yazınca yeniden aranır.
  void _onFocusChange() {
    if (!_focus.hasFocus) _reset();
  }

  void _reset() {
    _debounce?.cancel();
    _inflight?.cancel();
    _inflight = null;
    _seq++;
    if (_status != _Status.idle && mounted) {
      setState(() {
        _status = _Status.idle;
        _results = const [];
        _total = 0;
      });
    }
  }

  void _onChanged(String value) {
    widget.onChanged(value);
    if (!widget.catalogEnabled) return;
    final q = value.trim();
    if (q.length < kProductSuggestMinChars || q == _pickedName) {
      _reset();
      return;
    }
    _pickedName = null;
    _debounce?.cancel();
    _debounce = Timer(kProductSuggestDebounce, () => _search(q));
  }

  Future<void> _search(String q) async {
    _inflight?.cancel();
    final token = CancelToken();
    _inflight = token;
    final seq = ++_seq;
    setState(() => _status = _Status.loading);
    try {
      final page = await ref.read(productsRepositoryProvider).suggest(q, cancelToken: token);
      if (!mounted || seq != _seq) return;
      setState(() {
        _results = page.products;
        _total = page.total;
        _status = page.products.isEmpty ? _Status.empty : _Status.results;
      });
    } catch (e) {
      if (!mounted || seq != _seq || token.isCancelled) return;
      final offline = e is ApiException && (e.kind == ApiErrorKind.network || e.kind == ApiErrorKind.timeout);
      setState(() {
        _results = const [];
        _total = 0;
        _status = offline ? _Status.offline : _Status.failed;
      });
    } finally {
      if (identical(_inflight, token)) _inflight = null;
    }
  }

  void _pick(Product p) {
    _debounce?.cancel();
    _inflight?.cancel();
    _seq++;
    _pickedName = p.name.trim();
    widget.controller.value = TextEditingValue(
      text: p.name,
      selection: TextSelection.collapsed(offset: p.name.length),
    );
    setState(() {
      _status = _Status.idle;
      _results = const [];
      _total = 0;
    });
    widget.onPicked(p);
    // Klavye kapanır: doldurulan birim ve fiyat küçük ekranda görünsün.
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final field = TextFormField(
      controller: widget.controller,
      focusNode: _focus,
      decoration: InputDecoration(
        labelText: widget.label,
        isDense: true,
        hintText: widget.catalogEnabled ? 'Katalogda ara ya da serbest yaz' : null,
      ),
      textCapitalization: TextCapitalization.sentences,
      validator: widget.validator,
      onChanged: _onChanged,
    );
    if (!widget.catalogEnabled || _status == _Status.idle) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        // Önerilere dokunmak alanın "dışına dokunmak" sayılmasın: odak ve
        // klavye seçim anına kadar alanda kalır.
        TextFieldTapRegion(child: _panel()),
      ],
    );
  }

  Widget _panel() {
    final Widget content;
    switch (_status) {
      case _Status.loading when _results.isEmpty:
      case _Status.idle:
        content = _note(const ValueKey('offer-product-suggestions-loading'), Icons.search, 'Katalogda aranıyor…');
      case _Status.empty:
        content = _note(
          const ValueKey('offer-product-suggestions-empty'),
          Icons.info_outline,
          'Katalogda eşleşen ürün yok. Yazdığın ad serbest kalem olarak eklenir.',
        );
      case _Status.offline:
        content = _note(
          const ValueKey('offer-product-suggestions-offline'),
          Icons.cloud_off_outlined,
          'Bağlantı yok: katalog önerileri gösterilemiyor. Yazdığın ad serbest kalem olarak kalır.',
        );
      case _Status.failed:
        content = _note(
          const ValueKey('offer-product-suggestions-failed'),
          Icons.error_outline,
          'Katalog önerileri alınamadı. Yazdığın ad serbest kalem olarak kalır.',
        );
      case _Status.loading:
      case _Status.results:
        final more = _total - _results.length;
        final foreign = currencyLabel(widget.offerCurrency) != 'TL';
        content = Column(
          key: const ValueKey('offer-product-suggestions'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (foreign) ...[
              _note(
                const ValueKey('offer-product-suggestions-currency'),
                Icons.currency_exchange,
                'Katalog fiyatları TL; bu teklif ${currencyLabel(widget.offerCurrency)}. '
                'Seçince fiyat çevrilmeden yazılır, kontrol et.',
              ),
              const Divider(height: 1),
            ],
            for (var i = 0; i < _results.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              _SuggestionRow(product: _results[i], onTap: () => _pick(_results[i])),
            ],
            if (more > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.sm),
                child: Text('+$more ürün daha; aramayı daraltmak için yazmaya devam et', style: AppTypography.helper),
              ),
          ],
        );
    }
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.xs),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }

  Widget _note(Key key, IconData icon, String text) => Padding(
        key: key,
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: AppColors.textMuted),
            const SizedBox(width: 6),
            Expanded(child: Text(text, style: AppTypography.helper)),
          ],
        ),
      );
}

/// Tek öneri: ad (iki satıra kadar), kategori · tedarikçi, sağda satış
/// fiyatı ve birimi. Fiyat, katalogdaki satış fiyatıdır (kâr oranı
/// uygulanmış) -- products.read olan herkesin zaten gördüğü değer.
class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.product, required this.onTap});
  final Product product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = product;
    final meta = [
      if (p.category.isNotEmpty) p.category,
      if (!p.isManual) sourceLabels(p.source).short,
    ].join(' · ');
    return InkWell(
      key: ValueKey('offer-product-suggestion-${p.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.name,
                    style: AppTypography.body.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (meta.isNotEmpty)
                    Text(meta, style: AppTypography.helper, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(Formatters.money(p.unitPrice), style: AppTypography.metadata.copyWith(fontWeight: FontWeight.w700)),
                if (p.unit.isNotEmpty) Text('/ ${p.unit}', style: AppTypography.helper),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
