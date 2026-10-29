import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/formatters.dart';
import '../domain/offer.dart';

/// Teklif kaleminin müşteriye gösterilmeyen "Maliyet ve Kâr" bölümü --
/// form, teklif detayı ve revizyon detayı AYNI sözcükleri kullanır. Eskiden
/// "İç Fiyatlandırma / Fiyat Modu: Markup / Manuel satış / İç taşeron
/// maliyeti / Efektif markup" yazıyordu; sahada ve ofiste kimse anlamıyordu
/// ("Markup ve satış yerini kimse anlamıyor"). API değerleri (`markup` /
/// `manual`, `internal_subcontract_cost`, `markup_percent`) DEĞİŞMEDİ.
const kOfferPricingTitle = 'Maliyet ve Kâr';
const kOfferPricingPrivate = 'Müşteri görmez';
const kOfferPricingModeLabel = 'Fiyat nasıl belirlensin?';
const kOfferPricingCostLabel = 'Bize maliyeti (birim)';
const kOfferPricingMarkupLabel = 'Kâr oranı (%)';

/// Fiyat belirleme seçenekleri, formdaki sırasıyla: API değeri ->
/// (başlık, tek satır açıklama). '' = bu kalemde iç fiyatlama yok.
const kOfferPricingModes = <String, (String, String)>{
  OfferItem.pricingModeManual: ('Satış fiyatını ben gireyim', 'Müşteri fiyatını sen yazarsın; kârın hesaplanır'),
  OfferItem.pricingModeMarkup: ('Kâr oranıyla hesapla', 'Maliyetin üstüne kâr yüzdesi eklenir'),
  '': ('Kullanma', 'Bu kalemde maliyet ve kâr tutulmaz'),
};

final _percentFormat = NumberFormat.decimalPattern('tr_TR')
  ..minimumFractionDigits = 0
  ..maximumFractionDigits = 2;

/// "%15", "%12,75" (Türkçe yazımda % başta). Kâr oranı 2 ondalıklı
/// saklanır; Formatters.percent tek ondalığa yuvarlardı.
String formatOfferPercent(double value) => '%${_percentFormat.format(value)}';

/// Bölümün kutusu: kilit + başlık + "Müşteri görmez". Renkle SINIRLI
/// kalmayan bir ayrım (kilit ikonu, açık başlık, alt metin) ve durum
/// renklerinden (success/warning/danger/info) KASITLI OLARAK ayrı nötr/koyu
/// bir ton -- bu bir "durum" değil, "gizlilik" ekseni.
class OfferPricingBox extends StatelessWidget {
  const OfferPricingBox({super.key, required this.children, this.dense = false});

  final List<Widget> children;

  /// Detay/revizyon kartında küçük başlık ve dar iç boşluk.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final titleStyle = dense
        ? AppTypography.helper.copyWith(color: AppColors.navDark, fontWeight: FontWeight.w700)
        : AppTypography.cardTitle.copyWith(color: AppColors.navDark);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(dense ? AppSpacing.sm : AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.navDark.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: AppColors.navDark.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_outline, size: dense ? 14 : 16, color: AppColors.navDark),
              const SizedBox(width: 6),
              Flexible(child: Text(kOfferPricingTitle, style: titleStyle)),
            ],
          ),
          Padding(
            padding: EdgeInsets.only(left: dense ? 20 : 22, top: 2, bottom: dense ? 4 : AppSpacing.sm),
            child: Text(kOfferPricingPrivate, style: AppTypography.helper),
          ),
          ...children,
        ],
      ),
    );
  }
}

/// Formdaki canlı sonuç (her iki modda): "Müşteriye birim fiyat: X ·
/// Kârımız: Y (%Z)" ve kalem toplamı. Sayılar sunucunun kayıtta yazacağıyla
/// aynı kuralla hesaplanır (bkz. previewMarkupUnitPrice / offerItemProfit);
/// eksik alan varsa ne yazılacağı söylenir.
class OfferPricingResult extends StatelessWidget {
  const OfferPricingResult({
    super.key,
    required this.markup,
    required this.unitPrice,
    required this.unitCost,
    required this.quantity,
    this.currency = 'TRY',
  });

  /// Kâr oranıyla mı (fiyat hesaplanıyor) yoksa elle mi girildi.
  final bool markup;
  final double? unitPrice;
  final double? unitCost;
  final double? quantity;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final base = AppTypography.helper.copyWith(color: AppColors.textPrimary, height: 1.4);
    final bold = base.copyWith(fontWeight: FontWeight.w700);
    String money(double v) => Formatters.money(v, currency: currency);
    final price = unitPrice;
    final cost = unitCost;

    // Her parça ("Müşteriye birim fiyat: 1.150,00 TL", "Kârımız: 150,00 TL
    // (%15)") kendi içinde bölünmez boşlukla yazılır: dar ekranda satır
    // yalnızca " · " ayracında kırılır, "Kârımız:" ile tutarı ayrı satıra
    // düşmez.
    TextSpan seg(String text, [TextStyle? style]) => TextSpan(text: text.replaceAll(' ', kNbsp), style: style);
    const sep = TextSpan(text: '$kNbsp· ');

    final List<InlineSpan> unitLine;
    List<InlineSpan>? totalLine;
    if (price == null) {
      unitLine = [
        seg('Müşteriye birim fiyat: '),
        TextSpan(text: '—', style: bold),
        sep,
        TextSpan(
          text: markup ? 'maliyeti ve kâr oranını yazınca hesaplanır' : 'birim fiyatı yaz',
          style: AppTypography.helper,
        ),
      ];
    } else {
      final profit = cost == null ? null : offerItemProfit(unitPrice: price, unitCost: cost, quantity: quantity);
      final loss = profit != null && profit.unitProfit < 0;
      final profitStyle = bold.copyWith(color: loss ? AppColors.danger : AppColors.success);
      unitLine = [
        seg('Müşteriye birim fiyat: '),
        seg(money(price), bold),
        sep,
        if (profit == null)
          TextSpan(text: 'Kârımız: maliyeti yazınca görünür', style: AppTypography.helper)
        else ...[
          seg(loss ? 'Zararımız: ' : 'Kârımız: '),
          seg(money(profit.unitProfit.abs()), profitStyle),
          if (profit.percent != null) seg(' (${formatOfferPercent(profit.percent!.abs())})'),
        ],
      ];
      final q = quantity;
      if (q != null && q > 0) {
        final lineProfit = profit?.lineProfit;
        totalLine = [
          seg('Kalem toplamı: '),
          seg(money(offerLineTotal(q, price)), bold),
          if (lineProfit != null) ...[
            sep,
            seg(lineProfit < 0 ? 'Zararımız: ' : 'Kârımız: '),
            seg(money(lineProfit.abs()), profitStyle),
          ],
        ];
      }
    }
    return Column(
      key: const ValueKey('offer-pricing-result'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(TextSpan(style: base, children: unitLine)),
        if (totalLine != null) Text.rich(TextSpan(style: base, children: totalLine)),
      ],
    );
  }
}

/// Kayıtlı kalemin "Maliyet ve Kâr" özeti (teklif ve revizyon detayı,
/// `offers.internal_pricing.read`). Birim kâr ve oran sunucudan
/// (`expected_profit`, `effective_markup_percent`); kalemdeki kâr satır
/// toplamından türetilir.
class OfferItemProfitSummary extends StatelessWidget {
  const OfferItemProfitSummary({super.key, required this.item, this.currency = 'TRY'});

  final OfferItem item;
  final String currency;

  @override
  Widget build(BuildContext context) {
    String money(double v) => Formatters.money(v, currency: currency);
    final cost = item.internalSubcontractCost;
    final per = item.unit.trim().isEmpty ? 'birim' : item.unit.trim();
    final markup = item.pricingMode == OfferItem.pricingModeMarkup;
    final profit = item.expectedProfit;
    final loss = profit != null && profit < 0;
    final lineProfit = cost == null ? null : offerItemProfit(
      unitPrice: item.unitPrice,
      unitCost: cost,
      quantity: item.quantity,
    ).lineProfit;
    final percent = item.effectiveMarkupPercent;
    return OfferPricingBox(
      dense: true,
      children: [
        if (cost != null) Text('Bize maliyeti: ${money(cost)} / $per', style: AppTypography.helper),
        if (markup && item.markupPercent != null)
          Text('Kâr oranı: ${formatOfferPercent(item.markupPercent!)} · fiyat bundan hesaplandı',
              style: AppTypography.helper)
        else if (item.pricingMode == OfferItem.pricingModeManual)
          Text('Satış fiyatı elle girildi', style: AppTypography.helper),
        if (profit != null)
          Text(
            // Parçalar kendi içinde bölünmez (bkz. OfferPricingResult).
            [
              '${loss ? 'Beklenen zarar' : 'Beklenen kâr'}: ${money(profit.abs())} / $per'
                  '${percent != null ? ' (${formatOfferPercent(percent.abs())})' : ''}',
              if (lineProfit != null) 'bu kalemde ${money(lineProfit.abs())}',
            ].map((part) => part.replaceAll(' ', kNbsp)).join('$kNbsp· '),
            style: AppTypography.helper.copyWith(
              color: loss ? AppColors.danger : AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    );
  }
}
