import '../budget/domain/budget.dart' show formatTrDecimalInput, parseTrDecimal;
import '../finance_plan/domain/finance_dates.dart' show parsePercentInput;

/// Satın alma / taşeron formlarının tutar ve miktar alanları -- bütçe, masraf
/// ve ek iş formlarıyla AYNI Türkçe kural ([parseTrDecimal]): "1.250" = bin
/// iki yüz elli, "1.250,50" = bin iki yüz elli virgül elli, "12,5" / "12.5" =
/// on iki buçuk. Eskiden `double.tryParse(x.replaceAll(',', '.'))` "1.250"yi
/// 1,25 okuyor, "1.250,50"yi hiç okuyamayıp satırı sessizce atlıyordu.
/// Sütunlar numeric(…, 2): en çok 2 ondalık. Boş ya da geçersizse `null`.
double? parseFormNumber(String raw) => parseTrDecimal(raw).value;

/// Mevcut bir değeri alana yazmak için (gruplamasız, ondalık virgül) --
/// [parseFormNumber] ile birebir geri okunur. `toString()` "1.125"i (bir
/// virgül on iki beş) yazardı; geri okununca binlik sayılıp 1125 olurdu.
String formNumberText(double? value) => formatTrDecimalInput(value);

/// Bir tutar/miktar alanının doğrulama hatası (null = geçerli). Boş alan
/// [required] ise [requiredMessage] döner; değer sıfırsa [allowZero]
/// değilse [positiveMessage].
String? formNumberError(
  String? raw, {
  bool required = true,
  bool allowZero = false,
  String requiredMessage = 'Zorunlu',
  String positiveMessage = 'Sıfırdan büyük olmalı',
}) {
  final parsed = parseTrDecimal(raw ?? '');
  if (parsed.error != null) return parsed.error;
  final value = parsed.value;
  if (value == null) return required ? requiredMessage : null;
  if (allowZero ? value < 0 : value <= 0) return positiveMessage;
  return null;
}

/// KDV / kesinti yüzdesi: nokta ve virgül ikisi de ondalık, binlik gruplama
/// YOK ([parsePercentInput]) -- "18.5" on sekiz buçuktur, "33.333" reddedilir.
/// Boşsa `null` (çağıran varsayılanını kullanır).
double? parseFormPercent(String raw) => parsePercentInput(raw);

/// Yüzde alanının hatası (null = geçerli): 0 ile 100 arası, en çok 2 ondalık.
String? formPercentError(String? raw, {bool required = false, String requiredMessage = 'Zorunlu'}) {
  final s = (raw ?? '').trim();
  if (s.isEmpty) return required ? requiredMessage : null;
  final value = parsePercentInput(s);
  if (value == null) return 'Geçerli bir oran gir (ör. 20 veya 2,5).';
  if (value > 100) return 'Oran en fazla %100 olabilir.';
  return null;
}
