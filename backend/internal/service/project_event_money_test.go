package service_test

// Proje olaylarının metadata'sına tutar yazan her anahtarın
// domain.ProjectEventMoneyKeys'te olduğunu zorlar: GET /projects/{id}/events
// finans izni olmayana yalnızca o listedeki anahtarları düşürür, listede
// olmayan yeni bir tutar anahtarı sessizce sızardı. DB gerektirmez -- servis
// paketinin KAYNAĞINI tarar (domain/dashboard_rules_test.go ile aynı yöntem).

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

// eventMetadataSinks: metadata'yı project_events'e yazan fonksiyonlar ve
// metadata argümanının sırası (-1 = son argüman).
var eventMetadataSinks = map[string]int{
	"logProjectEvent":          6,
	"applyChangeOrderDecision": -1,
}

// moneyLikeKey: tutar adı taşıyan anahtar. Kimlik/numara/sayı alanları
// (cost_code_id, po_no, item_count) tutar değildir.
var moneyLikeKey = regexp.MustCompile(`(^|_)(amount|total|payable|price|cost|value|paid|profit|margin|wage|salary|balance|receivable)(_|$)`)

func isMoneyLikeKey(k string) bool {
	if strings.HasSuffix(k, "_id") || strings.HasSuffix(k, "_no") || strings.HasSuffix(k, "_count") {
		return false
	}
	return moneyLikeKey.MatchString(k)
}

func stringLit(e ast.Expr) (string, bool) {
	lit, ok := e.(*ast.BasicLit)
	if !ok || lit.Kind != token.STRING {
		return "", false
	}
	s, err := strconv.Unquote(lit.Value)
	return s, err == nil
}

// literalKeys: düğümün altındaki map bileşik literallerinin ve m["k"] = v
// atamalarının string anahtarları. name boş değilse yalnızca o adlı
// değişkene yapılan atamalar sayılır.
func literalKeys(n ast.Node, name string, add func(string)) {
	ast.Inspect(n, func(node ast.Node) bool {
		switch x := node.(type) {
		case *ast.AssignStmt:
			for i, lhs := range x.Lhs {
				switch l := lhs.(type) {
				case *ast.Ident:
					if name != "" && l.Name == name && i < len(x.Rhs) {
						literalKeys(x.Rhs[i], "", add)
					}
				case *ast.IndexExpr:
					if id, ok := l.X.(*ast.Ident); ok && (name == "" || id.Name == name) {
						if k, ok := stringLit(l.Index); ok {
							add(k)
						}
					}
				}
			}
		case *ast.CompositeLit:
			if name != "" {
				return true
			}
			for _, elt := range x.Elts {
				if kv, ok := elt.(*ast.KeyValueExpr); ok {
					if k, ok := stringLit(kv.Key); ok {
						add(k)
					}
				}
			}
		}
		return true
	})
}

func TestProjectEventMoneyKeysCoverEveryEventAmount(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatalf("kaynak dosyalar listelenemedi: %v", err)
	}
	fset := token.NewFileSet()
	var parsed []*ast.File
	topFuncs := map[string]*ast.FuncDecl{}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatalf("%s ayrıştırılamadı: %v", f, err)
		}
		parsed = append(parsed, file)
		for _, decl := range file.Decls {
			if fd, ok := decl.(*ast.FuncDecl); ok && fd.Recv == nil {
				topFuncs[fd.Name.Name] = fd
			}
		}
	}

	keys := map[string][]string{} // anahtar -> yazıldığı yerler
	calls := 0
	for _, file := range parsed {
		for _, decl := range file.Decls {
			fd, ok := decl.(*ast.FuncDecl)
			if !ok || fd.Body == nil {
				continue
			}
			ast.Inspect(fd.Body, func(node ast.Node) bool {
				call, ok := node.(*ast.CallExpr)
				if !ok {
					return true
				}
				fn, ok := call.Fun.(*ast.Ident)
				if !ok {
					return true
				}
				idx, sink := eventMetadataSinks[fn.Name]
				if !sink {
					return true
				}
				if idx < 0 {
					idx = len(call.Args) - 1
				}
				if idx >= len(call.Args) {
					t.Errorf("%s: %s beklenenden az argüman alıyor", fset.Position(call.Pos()), fn.Name)
					return true
				}
				calls++
				pos := fset.Position(call.Pos()).String()
				add := func(k string) { keys[k] = append(keys[k], pos) }
				switch arg := call.Args[idx].(type) {
				case *ast.CompositeLit:
					literalKeys(arg, "", add)
				case *ast.Ident:
					// Yerel değişken (meta := map...; meta["x"] = ...) ya da
					// parametre (applyChangeOrderDecision'ın eventMeta'sı --
					// çağıranlar ayrıca sink olarak taranır).
					literalKeys(fd.Body, arg.Name, add)
				case *ast.CallExpr:
					helper, ok := arg.Fun.(*ast.Ident)
					if !ok || topFuncs[helper.Name] == nil {
						t.Errorf("%s: metadata tanınmayan bir çağrıdan geliyor -- bu testi güncelleyin", pos)
						return true
					}
					literalKeys(topFuncs[helper.Name].Body, "", add)
				default:
					t.Errorf("%s: metadata tanınmayan bir ifade (%T) -- bu testi güncelleyin", pos, arg)
				}
				return true
			})
		}
	}

	if calls < 60 {
		t.Fatalf("yalnızca %d olay yazımı bulundu -- tarama bozuk olabilir", calls)
	}
	for _, must := range []string{"amount", "grand_total", "contract_amount", "planned_amount"} {
		if _, ok := keys[must]; !ok {
			t.Fatalf("%q hiç bulunamadı -- tarama bozuk olabilir", must)
		}
	}

	var names []string
	for k := range keys {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, k := range names {
		if isMoneyLikeKey(k) && !domain.ProjectEventMoneyKeys[k] {
			t.Errorf("olay metadata'sı %q tutar anahtarını yazıyor (%s) ama domain.ProjectEventMoneyKeys'te yok -- finans izni olmayana sızar",
				k, strings.Join(keys[k], ", "))
		}
	}
	// Listedeki her anahtar gerçekten bir olayda yazılıyor olmalı (yazım hatası).
	for k := range domain.ProjectEventMoneyKeys {
		if _, ok := keys[k]; !ok {
			t.Errorf("domain.ProjectEventMoneyKeys %q içeriyor ama hiçbir olay bu anahtarı yazmıyor", k)
		}
	}
}

func TestWithoutMoneyMetadata(t *testing.T) {
	in := map[string]any{"collection_id": "c1", "amount": 1500.0, "invoice_no": "F-1", "grand_total": 10.0}
	out := domain.WithoutMoneyMetadata(in)
	if _, ok := out["amount"]; ok {
		t.Errorf("amount düşmeliydi: %v", out)
	}
	if _, ok := out["grand_total"]; ok {
		t.Errorf("grand_total düşmeliydi: %v", out)
	}
	if out["collection_id"] != "c1" || out["invoice_no"] != "F-1" {
		t.Errorf("tutar olmayan alanlar korunmalı: %v", out)
	}
	if in["amount"] != 1500.0 {
		t.Errorf("girdi değiştirilmemeli: %v", in)
	}
	if got := domain.WithoutMoneyMetadata(nil); got != nil {
		t.Errorf("nil girdi nil kalmalı: %v", got)
	}
	plain := map[string]any{"task_id": "t1"}
	if got := domain.WithoutMoneyMetadata(plain); len(got) != 1 || got["task_id"] != "t1" {
		t.Errorf("tutarsız metadata aynen dönmeli: %v", got)
	}
}
