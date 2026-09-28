package domain_test

// Ana sayfa kural kataloğu ve "Son Hareketler" izin haritasının tutarlılığı
// (spec §3.1, §4.9). DB gerektirmez.

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/Savanooo/ARVEND/backend/internal/domain"
)

// projectEventConstants, domain paketinin KAYNAĞINI tarayıp adı
// "ProjectEvent" ile başlayan TÜM string sabitlerini döner -- Go'da
// sabitler çalışma zamanında listelenemediği için, yeni eklenen bir olay
// tipinin haritaya eklenmesi unutulursa bu test yakalar.
func projectEventConstants(t *testing.T) map[string]string {
	t.Helper()
	fset := token.NewFileSet()
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatalf("kaynak dosyalar listelenemedi: %v", err)
	}
	out := map[string]string{}
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("%s okunamadı: %v", f, err)
		}
		file, err := parser.ParseFile(fset, f, src, 0)
		if err != nil {
			t.Fatalf("%s ayrıştırılamadı: %v", f, err)
		}
		for _, decl := range file.Decls {
			gd, ok := decl.(*ast.GenDecl)
			if !ok || gd.Tok != token.CONST {
				continue
			}
			for _, spec := range gd.Specs {
				vs := spec.(*ast.ValueSpec)
				for i, name := range vs.Names {
					if !strings.HasPrefix(name.Name, "ProjectEvent") || i >= len(vs.Values) {
						continue
					}
					lit, ok := vs.Values[i].(*ast.BasicLit)
					if !ok || lit.Kind != token.STRING {
						continue
					}
					v, err := strconv.Unquote(lit.Value)
					if err != nil {
						t.Fatalf("%s: %v", name.Name, err)
					}
					out[name.Name] = v
				}
			}
		}
	}
	return out
}

func TestActivityEventPermissionsCoverEveryProjectEvent(t *testing.T) {
	consts := projectEventConstants(t)
	if len(consts) < 90 {
		t.Fatalf("yalnızca %d ProjectEvent* sabiti bulundu -- tarama bozuk olabilir", len(consts))
	}
	for name, value := range consts {
		_, mapped := domain.ActivityEventPermissions[value]
		excluded := domain.ActivityEventExcluded[value]
		if !mapped && !excluded {
			t.Errorf("%s (%q) ne ActivityEventPermissions'ta ne ActivityEventExcluded'da -- akış için izin kararı verilmeli", name, value)
		}
		if mapped && excluded {
			t.Errorf("%s (%q) hem haritada hem hariç listesinde", name, value)
		}
	}
	// Haritadaki her tip gerçekten bir sabite karşılık gelmeli (yazım hatası).
	known := map[string]bool{}
	for _, v := range consts {
		known[v] = true
	}
	for eventType, perm := range domain.ActivityEventPermissions {
		if !known[eventType] {
			t.Errorf("haritadaki %q hiçbir ProjectEvent* sabitine karşılık gelmiyor", eventType)
		}
		if perm == "" {
			t.Errorf("%q için izin boş", eventType)
		}
	}
}

func TestActivityFinanceEventsNeedFinanceRead(t *testing.T) {
	// Tutar taşıyan finans olayları (metadata seçilmese bile) projects.read
	// ile ASLA akışa girmemeli (GET /projects/{id}/events sızıntısı
	// tekrarlanmasın).
	for _, ev := range []string{
		domain.ProjectEventCollectionReceived, domain.ProjectEventExpenseAdded,
		domain.ProjectEventSubcontractorPaymentMade, domain.ProjectEventChangeOrderApproved,
		domain.ProjectEventInvoiceCreated, domain.ProjectEventPaymentPlanCreated,
	} {
		if got := domain.ActivityEventPermissions[ev]; got != domain.PermProjectsFinanceRead {
			t.Errorf("%s izni = %q, beklenen %q", ev, got, domain.PermProjectsFinanceRead)
		}
	}
	fieldPerms := map[string]bool{
		domain.PermProjectsRead: true, domain.PermProjectsTasksRead: true, domain.PermProjectsTasksUpdate: true,
		domain.PermProjectsOperationsRead: true, domain.PermProjectsOperationsManage: true,
		domain.PermAttendanceRead: true, domain.PermNotificationsRead: true,
	}
	allowed := domain.AllowedProjectActivityTypes(func(c string) bool { return fieldPerms[c] })
	for _, ev := range allowed {
		if perm := domain.ActivityEventPermissions[ev]; !fieldPerms[perm] {
			t.Errorf("saha rolüne izinsiz olay tipi açıldı: %s (%s)", ev, perm)
		}
		if ev == domain.ProjectEventCollectionReceived {
			t.Error("saha rolü collection_received görmemeli")
		}
	}
	if len(allowed) == 0 {
		t.Error("saha rolü hiçbir olay tipini göremiyor -- görev/şantiye olayları açık olmalı")
	}
}

func TestAttentionRulesAreWellFormed(t *testing.T) {
	modules := map[string]bool{}
	for _, k := range domain.DashboardSectionKeys {
		modules[k] = true
	}
	severities := map[string]bool{domain.SeverityDanger: true, domain.SeverityAction: true, domain.SeverityInfo: true}
	if len(domain.AttentionRules) != 29 {
		t.Errorf("AttentionRules %d kod içeriyor, spec §3.1 29 kod tanımlar", len(domain.AttentionRules))
	}
	for code, rule := range domain.AttentionRules {
		if !modules[rule.Module] {
			t.Errorf("%s: bilinmeyen modül %q", code, rule.Module)
		}
		if !severities[rule.Severity] {
			t.Errorf("%s: bilinmeyen önem %q", code, rule.Severity)
		}
		if len(rule.Visible) == 0 {
			t.Errorf("%s: görünürlük izni yok", code)
		}
		if rule.AlwaysMine && (len(rule.Act) > 0 || rule.WhenCannotAct != "") {
			t.Errorf("%s: AlwaysMine ile Act/WhenCannotAct birlikte kullanılmamalı", code)
		}
		if !rule.AlwaysMine && rule.WhenCannotAct != "" && rule.WhenCannotAct != domain.LaneWatching {
			t.Errorf("%s: WhenCannotAct yalnızca watching ya da boş olabilir", code)
		}
	}
	if len(domain.DashboardSectionKeys) != 20 {
		t.Errorf("bölüm sayısı %d, beklenen 20", len(domain.DashboardSectionKeys))
	}
}
