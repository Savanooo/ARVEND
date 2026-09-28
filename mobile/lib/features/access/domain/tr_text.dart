/// Türkçe büyük/küçük harf -- Dart'ın `toUpperCase`/`toLowerCase`'i
/// "i/İ" ve "ı/I" çiftlerini bozar ("istanbul" -> "ISTANBUL").
String trUpper(String s) => s.replaceAll('i', 'İ').replaceAll('ı', 'I').toUpperCase();

String trLower(String s) => s.replaceAll('İ', 'i').replaceAll('I', 'ı').toLowerCase();

/// Arama için sadeleştirilmiş biçim: Türkçe küçük harf + noktasız/noktalı
/// i ayrımı kaldırılır ("Işık" araması "isik"i de bulsun).
String searchKey(String s) => trLower(s).replaceAll('ı', 'i').trim();
