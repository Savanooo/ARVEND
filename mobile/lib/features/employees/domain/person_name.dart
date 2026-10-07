/// Backend `domain.NormalizePersonName` ile BİREBİR aynı kural: iki ad
/// soyadın "aynı kişi adı" olup olmadığını karşılaştırma anahtarı (gösterim
/// için değil). Türkçe harfler ASCII'ye katlanır (İ/I/ı/i -> i, ş -> s ...),
/// büyük/küçük harf ve fazla boşluk yok sayılır.
///
/// Neden mobilde de var: "Yeni Kullanıcı" formu, sunucunun hesabı hangi
/// personele bağlayacağını kaydetmeden ÖNCE gösterir (aynı adlı bağlantısız
/// personel varsa önceden seçili gelir). Kural sunucuyla ayrışırsa form bir
/// şey, sunucu başka bir şey yapardı.
String normalizePersonName(String s) {
  final words = s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  final out = StringBuffer();
  var first = true;
  for (final word in words) {
    if (!first) out.write(' ');
    first = false;
    for (final rune in word.runes) {
      if (rune == 0x0307) continue; // "i + birleşik nokta"
      out.write(_fold(String.fromCharCode(rune)));
    }
  }
  return out.toString();
}

/// İki ad aynı kişi adı mı (boş ad hiçbir adla eşleşmez).
bool samePersonName(String a, String b) {
  final na = normalizePersonName(a);
  return na.isNotEmpty && na == normalizePersonName(b);
}

String _fold(String ch) => switch (ch) {
  'İ' || 'I' || 'ı' || 'i' || 'Î' || 'î' => 'i',
  'Ş' || 'ş' => 's',
  'Ğ' || 'ğ' => 'g',
  'Ü' || 'ü' || 'Û' || 'û' => 'u',
  'Ö' || 'ö' => 'o',
  'Ç' || 'ç' => 'c',
  'Â' || 'â' => 'a',
  _ => ch.toLowerCase(),
};
