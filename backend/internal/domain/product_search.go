package domain

import (
	"regexp"
	"strings"
	"unicode"
)

// Ürün kataloğu araması (GET /products?q=). Eskiden sorgu TEK bir alt dize
// olarak normalized_name içinde aranıyordu: "demir" hiçbir şey bulmuyordu
// (Demir Profil ürün adında değil tedarikçi adında geçer), "kutu 40" ise
// adın içinde tam olarak "kutu 40" yan yana durmadıkça boş dönüyordu --
// sahadan gelen şikâyet: "teklifte ürün adı yazınca ürün gelmiyor".
//
// Kural: sorgu kelimelere bölünür; ürün, HER kelime adında YA DA
// kategorisinde YA DA tedarikçisinde (kaynak kodu + görünen adı) geçiyorsa
// eşleşir. Karşılaştırma iki tarafta da aynı katlamayla yapılır
// (ProductSearchFold); SQL tarafı products.sql'deki SearchProducts'tır ve
// bu dosyadaki kurallarla BİREBİR aynı olmalıdır (TestProductSearchScale
// ikisini 4000 üründe karşılaştırır).

// MaxProductSearchTerms: bundan fazla kelime yok sayılır. Her kelime her
// satırda üç alanda aranır; sınırsız bir sorgu taramayı katlayarak büyütür.
const MaxProductSearchTerms = 8

// maxProductSearchRunes: sorgunun okunan uzunluğu (ürün adı en fazla 200).
const maxProductSearchRunes = 200

// searchSymbolFold: ölçülerde "×" (Demir Profil adlarında), klavyeden
// yazılan "x"/"X" ya da "*" aynı şeydir: "40x40" yazan "40×40"ı bulmalı.
// Ondalık virgül/nokta da öyle: adda "1,35", kullanıcı "1.35" yazabilir.
// SQL karşılığı: replace(replace(replace(..., '×', 'x'), '*', 'x'), ',', '.').
var searchSymbolFold = strings.NewReplacer("×", "x", "*", "x", ",", ".")

// sizeSeparator: "40 x 40" -> "40x40". Adda da sorguda da boşluklu yazım
// olabilir; iki taraf aynı biçime iner. Go'nun regexp'i ileriye bakmayı
// (?=) desteklemez: tek rakamlı zincirde ("4 x 5 x 6") ortadaki rakam ilk
// eşleşmede tüketilir, bu yüzden desen en az BİR boşluk ister (zaten
// bitişik "4x5" yeniden eşleşip "5"i yutmasın) ve değişiklik kalmayana
// kadar tekrarlanır. SQL karşılığı (ileriye bakan, tek geçiş, sembol
// katlamasından önce): regexp_replace(..., '(\d) *[x×*] *(?=\d)', '\1x', 'g').
var sizeSeparator = regexp.MustCompile(`(\d)(?: +x *| *x +)(\d)`)

// ProductSearchFold, metni arama karşılaştırmasının biçimine indirir:
// NormalizeName (Türkçe harf katlama + küçük harf) + ölçü/ondalık
// sembolleri + boşluklu ölçü yazımı. normalized_name'in KENDİSİ
// değiştirilmez: mükerrer ürün tespiti ve senkron eşleştirmesi onu olduğu
// gibi karşılaştırır (bkz. calc_catalog_provision.go); "×"ı orada katlamak
// mevcut satırlarla eşleşmeyi bozardı. Bu katlama yalnızca aramadadır.
func ProductSearchFold(s string) string {
	s = searchSymbolFold.Replace(NormalizeName(s))
	for {
		next := sizeSeparator.ReplaceAllString(s, "${1}x${2}")
		if next == s {
			return s
		}
		s = next
	}
}

// ProductSearchTerms, kullanıcının yazdığı sorguyu aranacak kelimelere
// böler: katlanır, boşluklardan bölünür, kelime başındaki/sonundaki
// noktalama atılır ("kutu," -> "kutu"; "1.35" içindeki nokta kalır),
// tekrarlar ve boş parçalar düşer, en fazla MaxProductSearchTerms kelime.
// Boş sorgu -> nil (filtre yok, liste ad sırasıyla döner).
func ProductSearchTerms(q string) []string {
	if r := []rune(q); len(r) > maxProductSearchRunes {
		q = string(r[:maxProductSearchRunes])
	}
	var terms []string
	seen := map[string]bool{}
	for _, field := range strings.Fields(ProductSearchFold(q)) {
		t := strings.TrimFunc(field, func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
		if t == "" || seen[t] {
			continue
		}
		seen[t] = true
		terms = append(terms, t)
		if len(terms) == MaxProductSearchTerms {
			break
		}
	}
	return terms
}

// ProductSearchSources, tedarikçi eşleşmesi için kayıt defterindeki her
// kaynağın kodunu ve aranabilir etiketini (kod + görünen ad + kısa ad,
// katlanmış) paralel dizilerle döner: "demir", "profil", "omega", "çelik"
// -> demirprofil; "ulaş"/"ulas" -> ulas. Kaynak adları SQL'e gömülmez --
// kayıt defteri tek doğru kaynaktır, yeni bir tedarikçi kendiliğinden
// aranabilir olur.
func ProductSearchSources() (codes, labels []string) {
	for _, s := range priceSourceRegistry {
		codes = append(codes, s.Code)
		labels = append(labels, ProductSearchFold(s.Code+" "+s.Name+" "+s.ShortName))
	}
	return codes, labels
}

// likeEscaper: LIKE desenindeki joker karakterler ("%", "_") ve kaçış
// karakterinin kendisi düz metin olsun (Postgres'in varsayılan kaçışı "\").
// Eskiden sorgu desene olduğu gibi giriyordu: "s_c" "sac"ı buluyordu.
var likeEscaper = strings.NewReplacer(`\`, `\\`, "%", `\%`, "_", `\_`)

// ProductSearchPatterns, kelimelerin SearchProducts'a giden LIKE
// desenleridir: contains "%kelime%" (herhangi bir yerde), wordStart
// "% kelime%" (bir kelimenin başında -- SQL adın önüne boşluk koyar).
func ProductSearchPatterns(terms []string) (contains, wordStart []string) {
	contains = make([]string, len(terms))
	wordStart = make([]string, len(terms))
	for i, t := range terms {
		e := likeEscaper.Replace(t)
		contains[i] = "%" + e + "%"
		wordStart[i] = "% " + e + "%"
	}
	return contains, wordStart
}
