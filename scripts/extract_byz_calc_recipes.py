#!/usr/bin/env python3
"""
extract_byz_calc_recipes.py — BYZ Metraj Hesaplama seed verisini (16
grup, 95 kategori, 814 reçete kalemi) ARVEND'e taşımak için TEK SEFERLİK
bir dışa aktarma aracıdır.

SALT-OKUNUR ve İZOLE: BYZ kaynak dosyasını (material_calculation_service.py)
ASLA import etmez / çalıştırmaz -- yalnızca Python'ın kendi `ast` modülüyle
STATİK olarak ayrıştırır ve `seed_calculation_data()` fonksiyonu içindeki
dört yerel değişkenin (groups_to_seed, group_assignments,
categories_to_seed, recipes_per_category) SAF LİTERAL değerlerini
`ast.literal_eval` ile okur. Hiçbir Mongo bağlantısı açılmaz, hiçbir BYZ
kodu çalıştırılmaz, hiçbir şey silinmez/değiştirilmez.

Çıktılar:
  1. backend/db/fixtures/byz_calc_recipes.json -- ARVEND import aracının
     (cmd/import-calc-recipes) okuduğu, gruplar/kategoriler/reçete
     kalemlerini ARVEND alan adlarına eşlenmiş hâliyle taşıyan fixture.
  2. docs/byz-metraj-import-veri-kalitesi-raporu.md -- İÇE AKTARIMDAN
     ÖNCE raporlanması istenen sorunlar (m2/m² tutarsızlığı, metre/m,
     paket/adet, "L Köşebent" gibi perimeter-şüphesi satırlar, "Dübel
     Vida" gibi şüpheli katsayılar, 0 TL fiyatlı ürünler). Bu sorunlar
     BURADA SESSİZCE DÜZELTİLMEZ -- yalnızca listelenir; düzeltme kararı
     ayrı, bilinçli bir adımdır (fixture'daki alanlar BYZ'deki HAM
     değerleri taşır).

Kullanım:
    python3 scripts/extract_byz_calc_recipes.py \
        --byz-file /path/to/byz-app/erp_teklif_sistemi/services/material_calculation_service.py
"""

from __future__ import annotations

import argparse
import ast
import json
import os
from collections import Counter, defaultdict


def _safe_eval(node: ast.AST):
    """ast.literal_eval'in bir üst kümesi: saf literaller (str/int/float/
    list/dict/tuple/bool/None) DIŞINDA, YALNIZCA sabitler arası aritmetik
    ifadeleri (ör. BYZ'deki "qty": 1/3.6, 1/50 gibi paket-kapsama
    katsayıları) de kabul eder -- +, -, *, /, üner eksi. Fonksiyon çağrısı,
    isim/attribute erişimi, import vb. HİÇBİR ŞEY çalıştırılmaz; tanınmayan
    bir düğüm türü görülürse hata verir (sessizce yanlış bir değer üretmez).
    """
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.List):
        return [_safe_eval(e) for e in node.elts]
    if isinstance(node, ast.Tuple):
        return tuple(_safe_eval(e) for e in node.elts)
    if isinstance(node, ast.Dict):
        return {_safe_eval(k): _safe_eval(v) for k, v in zip(node.keys, node.values)}
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.USub, ast.UAdd)):
        v = _safe_eval(node.operand)
        return -v if isinstance(node.op, ast.USub) else v
    if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Add, ast.Sub, ast.Mult, ast.Div)):
        left, right = _safe_eval(node.left), _safe_eval(node.right)
        if isinstance(node.op, ast.Add):
            return left + right
        if isinstance(node.op, ast.Sub):
            return left - right
        if isinstance(node.op, ast.Mult):
            return left * right
        return left / right
    raise ValueError(f"desteklenmeyen ifade türü: {ast.dump(node)[:120]}")


def extract_literal_assignments(py_source_path: str, names: set[str]) -> dict:
    """seed_calculation_data() fonksiyonu içindeki verilen isimli yerel
    değişken atamalarını, kaynağı ÇALIŞTIRMADAN, AST üzerinden okur."""
    with open(py_source_path, "r", encoding="utf-8") as f:
        source = f.read()
    tree = ast.parse(source, filename=py_source_path)

    func_node = None
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == "seed_calculation_data":
            func_node = node
            break
    if func_node is None:
        raise SystemExit("HATA: seed_calculation_data() fonksiyonu bulunamadı -- BYZ kaynak dosyası değişmiş olabilir.")

    found = {}
    for stmt in func_node.body:
        if isinstance(stmt, ast.Assign) and len(stmt.targets) == 1 and isinstance(stmt.targets[0], ast.Name):
            var_name = stmt.targets[0].id
            if var_name in names:
                try:
                    found[var_name] = _safe_eval(stmt.value)
                except ValueError as e:
                    raise SystemExit(f"HATA: {var_name} güvenli değerlendirilemedi: {e}")

    missing = names - found.keys()
    if missing:
        raise SystemExit(f"HATA: şu değişkenler bulunamadı: {missing}")
    return found


def build_fixture(data: dict) -> dict:
    groups_to_seed = data["groups_to_seed"]
    group_assignments = data["group_assignments"]
    categories_to_seed = data["categories_to_seed"]
    recipes_per_category = data["recipes_per_category"]

    # slug -> group_slug eşlemesi (BYZ'nin kendi mantığı: ilk eşleşen grup)
    category_to_group = {}
    for grp_slug, cat_slugs in group_assignments.items():
        for cslug in cat_slugs:
            category_to_group.setdefault(cslug, grp_slug)

    fixture_groups = []
    for g in groups_to_seed:
        fixture_groups.append({
            "slug": g["slug"], "name": g["name"], "description": g.get("description", ""),
            "sort_order": g["sort_order"],
        })

    fixture_categories = []
    for c in categories_to_seed:
        group_slug = category_to_group.get(c["slug"])
        fixture_categories.append({
            "slug": c["slug"], "name": c["name"], "description": c.get("description", ""),
            "group_slug": group_slug, "sort_order": c["sort_order"], "image": c.get("image"),
        })

    fixture_items = []
    for category_slug, items in recipes_per_category.items():
        for item in items:
            fixture_items.append({
                "category_slug": category_slug,
                "material_name": item["material_name"],
                "unit": item["unit"],
                "quantity_per_m2": item["qty"],  # BYZ'de tek tip formül area_based; bkz. rapor
                "reference_unit_price": item["price"],
                "group_name": item.get("group", ""),
                "sort_order": item.get("order", 0),
                "rounding_type": item.get("round", "none"),
            })

    return {"groups": fixture_groups, "categories": fixture_categories, "recipe_items": fixture_items}


def data_quality_report(fixture: dict) -> str:
    items = fixture["recipe_items"]
    lines = []
    lines.append("# BYZ Metraj Hesaplama — İçe Aktarım Öncesi Veri Kalitesi Raporu")
    lines.append("")
    lines.append(
        "Bu rapor, `scripts/extract_byz_calc_recipes.py` ile BYZ "
        "`material_calculation_service.py` içindeki `seed_calculation_data()` "
        "fonksiyonundan STATİK olarak (kod hiç çalıştırılmadan) çıkarılan "
        f"**{len(items)} reçete kalemi** üzerinde tespit edilen sorunları listeler. "
        "Hiçbir değer burada ya da fixture'da SESSİZCE düzeltilmedi -- "
        "fixture BYZ'deki HAM değerleri taşır; düzeltme ayrı, bilinçli bir "
        "admin işlemidir (bkz. `cmd/import-calc-recipes` sonrası admin ekranı, Faz M2)."
    )
    lines.append("")

    # 1) Birim tutarsızlıkları (m2 / m² / metre / m, paket/adet karışıklığı)
    units = Counter(it["unit"] for it in items)
    lines.append("## 1) Birim tutarsızlıkları")
    lines.append("")
    lines.append("Görülen tüm birimler ve kalem sayıları:")
    lines.append("")
    for u, c in sorted(units.items(), key=lambda kv: -kv[1]):
        lines.append(f"- `{u}` — {c} kalem")
    lines.append("")
    area_variants = [u for u in units if u.lower() in ("m2", "m²")]
    length_variants = [u for u in units if u.lower() in ("m", "metre")]
    if len(area_variants) > 1:
        lines.append(f"**m2 / m² tutarsızlığı:** aynı anlama gelen iki farklı yazım bulundu: {area_variants}. "
                      "Bunlar farklı string oldukları için (ARVEND'de `unit` serbest metindir) aynı malzeme "
                      "farklı birimlerle iki kez tanımlanmış gibi görünebilir.")
        lines.append("")
    if len(length_variants) > 1:
        lines.append(f"**metre / m tutarsızlığı:** {length_variants}.")
        lines.append("")
    name_units = defaultdict(set)
    for it in items:
        name_units[it["material_name"].strip().lower()].add(it["unit"])
    paket_adet_conflicts = {n: us for n, us in name_units.items() if len(us) > 1}
    if paket_adet_conflicts:
        lines.append("**Aynı malzeme adı farklı birimlerle kayıtlı (paket/adet vb. uyuşmazlıkları):**")
        lines.append("")
        for n, us in sorted(paket_adet_conflicts.items()):
            lines.append(f"- {n!r}: {sorted(us)}")
        lines.append("")

    # 2) L Köşebent gibi aslında perimeter bazlı olması muhtemel satırlar
    lines.append("## 2) Aslında çevre (perimeter) bazlı olması muhtemel satırlar")
    lines.append("")
    lines.append(
        "BYZ'nin motoru TÜM kalemleri `area_based` olarak seed eder (bkz. "
        "docs/byz-metraj-hesaplama-analizi.md §3.2) -- `perimeter_based` "
        "tip hiç kullanılmaz. Aşağıdaki `group_name` alanı 'Perimeter' "
        "olan ya da adı çevre/kenar/kösebent gibi kelimeler içeren kalemler, "
        "gerçekte alan yerine çevreyle orantılı olabilir; bu, alanla değil "
        "malzeme adı/etiketiyle tahmin edilmiştir, KESİN DEĞİLDİR:"
    )
    lines.append("")
    suspects = []
    for it in items:
        name_l = it["material_name"].lower()
        group_l = (it.get("group_name") or "").lower()
        if "perimeter" in group_l or any(k in name_l for k in ("köşebent", "kenar profili", "çıta")):
            suspects.append(it)
    if suspects:
        for it in suspects:
            lines.append(f"- {it['material_name']} (kategori: `{it['category_slug']}`, "
                          f"group_name: {it.get('group_name')!r}, qty/m²: {it['quantity_per_m2']})")
    else:
        lines.append("(bulunamadı)")
    lines.append("")

    # 3) Şüpheli katsayılar (ör. Dübel Vida gibi 1 paket/m²)
    lines.append("## 3) Şüpheli katsayılar (paket-tarzı birimler)")
    lines.append("")
    lines.append(
        "`quantity_per_m2` değeri 1 m² başına 1'e eşit ya da bundan büyük "
        "olan `paket`/`torba`/`rulo`/`top`/`teneke` kalemler (ör. 'Dübel "
        "Vida' — 1 paket/m² → 100 m² için 100 paket), gerçek dünyada "
        "mantıksız görünebilir; muhtemelen 'X paket, Y m² kaplar' şeklinde "
        "PAKET BAŞINA KAPSAMA olarak modellenmesi gerekirken doğrudan m² "
        "katsayısı olarak girilmiştir (bkz. yeni `package_size` alanı, "
        "Faz M1). `adet` birimi BİLİNÇLİ OLARAK bu listeye DAHİL EDİLMEDİ "
        "-- vida/dübel gibi malzemelerde yüksek adet/m² değeri normaldir, "
        "yanlış pozitif üretirdi. Bunlar TAHMİN olarak işaretlenmiştir, "
        "iş sahibiyle doğrulanmalıdır:"
    )
    lines.append("")
    weird = [it for it in items if it["unit"].lower() in ("paket", "torba", "rulo", "top", "teneke")
             and float(it["quantity_per_m2"]) >= 1]
    for it in sorted(weird, key=lambda x: -float(x["quantity_per_m2"]))[:40]:
        lines.append(f"- {it['material_name']} ({it['category_slug']}): {it['quantity_per_m2']} {it['unit']}/m²")
    if len(weird) > 40:
        lines.append(f"- … ve {len(weird) - 40} kalem daha (tam liste fixture'da).")
    lines.append("")

    # 4) 0 TL fiyatlı ürünler
    lines.append("## 4) 0 TL referans fiyatlı kalemler")
    lines.append("")
    zero_price = [it for it in items if float(it["reference_unit_price"]) == 0]
    lines.append(f"{len(zero_price)} / {len(items)} kalemin referans fiyatı 0 TL. Bu kalemler ARVEND'e "
                  "`product_id=NULL` olarak (ürün eşleşmesi yapılmadan) aktarılacak; hesaplama sırasında "
                  "`product_zero_price`/`product_missing` warning üretecekler (sessizce 0 TL ile geçmeyecekler).")
    lines.append("")
    by_category = Counter(it["category_slug"] for it in zero_price)
    if by_category:
        lines.append("Kategori başına 0 TL kalem sayısı (ilk 20):")
        lines.append("")
        for cat, cnt in by_category.most_common(20):
            lines.append(f"- `{cat}`: {cnt}")
        lines.append("")

    # 5) Aynı (isim, birim) farklı fiyat/katsayı ile birden çok kez (çelişki)
    lines.append("## 5) Aynı malzeme farklı kategorilerde çelişen referans fiyat")
    lines.append("")
    price_by_name_unit = defaultdict(set)
    for it in items:
        key = (it["material_name"].strip().lower(), it["unit"])
        price_by_name_unit[key].add(float(it["reference_unit_price"]))
    conflicts = {k: v for k, v in price_by_name_unit.items() if len(v) > 1}
    lines.append(f"{len(conflicts)} farklı (ad, birim) çiftinde birden fazla referans fiyat görüldü "
                  "(BYZ'de ürün ilk görülen fiyatı alıyordu, sonrakiler yalnızca reçete referansına yazılıyordu):")
    lines.append("")
    for (name, unit), prices in sorted(conflicts.items())[:30]:
        lines.append(f"- {name!r} ({unit}): {sorted(prices)}")
    if len(conflicts) > 30:
        lines.append(f"- … ve {len(conflicts) - 30} çift daha.")
    lines.append("")

    # 6) rounding_type=ceil + taban-10'da devirli (kesirli) katsayı riski
    lines.append("## 6) `ceil` yuvarlamalı + taban-10'da devirli katsayı riski")
    lines.append("")
    lines.append(
        "ARVEND `quantity_per_m2` kolonunu `numeric(14,6)` (6 ondalık hane) "
        "olarak saklar. BYZ'deki bazı `round: ceil` kalemleri (paket "
        "kapsaması modellenirken `1/N` biçiminde girilmiş) taban-10'da "
        "DEVİRLİ (örn. 1/3.6 = 0,2777...) katsayılar taşır; 6 haneye "
        "yuvarlamak gerçek değerden çok küçük bir sapma yaratır ve BYZ'nin "
        "kendi float64 gürültüsüyle yaşadığı sorunun (bkz. "
        "docs/byz-metraj-hesaplama-analizi.md §10, '10.8×1/3.6' örneği) "
        "benzerini üretebilir (bir paket fazla/eksik). ARVEND motoru bunu "
        "`package_size` alanıyla KESİN olarak çözer (bkz. "
        "internal/domain/calc.go) -- ama bu, YALNIZCA admin bu kalemleri "
        "`quantity_per_m2=1, package_size=<kapsama m²>` biçimine "
        "DÖNÜŞTÜRÜRSE devreye girer; içe aktarma bunu OTOMATİK yapmaz. "
        "Aşağıdaki kalemler bu dönüşüm için adaydır:"
    )
    lines.append("")
    from fractions import Fraction

    def terminates_in_decimal(value: float) -> bool:
        frac = Fraction(value).limit_denominator(10**6)
        d = frac.denominator
        for p in (2, 5):
            while d % p == 0:
                d //= p
        return d == 1

    ceil_risky = []
    for it in items:
        if it.get("rounding_type") == "ceil":
            v = float(it["quantity_per_m2"])
            if v > 0 and not terminates_in_decimal(v):
                ceil_risky.append(it)
    if ceil_risky:
        for it in ceil_risky:
            frac = Fraction(float(it["quantity_per_m2"])).limit_denominator(10**6)
            lines.append(f"- {it['material_name']} ({it['category_slug']}): "
                          f"quantity_per_m2={it['quantity_per_m2']!r} (≈ {frac.numerator}/{frac.denominator}) "
                          f"-> ÖNERİ: quantity_per_m2=1, package_size={frac.denominator/frac.numerator:.4g}")
    else:
        lines.append("(bulunamadı)")
    lines.append("")

    lines.append("## Özet")
    lines.append("")
    lines.append(f"- Toplam grup: {len(fixture['groups'])}")
    lines.append(f"- Toplam kategori: {len(fixture['categories'])}")
    lines.append(f"- Toplam reçete kalemi: {len(items)}")
    lines.append(f"- Farklı birim sayısı: {len(units)}")
    lines.append(f"- 0 TL fiyatlı kalem: {len(zero_price)}")
    lines.append(f"- Çevre-bazlı şüphesi taşıyan kalem: {len(suspects)}")
    lines.append(f"- Şüpheli paket katsayılı kalem (>=1 paket-tarzı birim/m²): {len(weird)}")
    lines.append(f"- Çelişen fiyatlı (ad, birim) çifti: {len(conflicts)}")
    lines.append(f"- `ceil` + devirli katsayı riski taşıyan kalem: {len(ceil_risky)}")
    lines.append("")
    lines.append(
        "**Karar bekleyen madde:** Yukarıdaki hiçbir sorun bu script tarafından "
        "düzeltilmedi. İçe aktarma (`cmd/import-calc-recipes`) fixture'ı OLDUĞU "
        "GİBİ (BYZ'deki ham hâliyle) organizasyonun `calc_*` tablolarına yazar; "
        "düzeltmeler admin ekranından (Faz M1 CRUD uçları) ya da fixture "
        "dosyası elle düzenlenip yeniden import edilerek yapılmalıdır."
    )
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--byz-file", required=True, help="BYZ material_calculation_service.py yolu")
    parser.add_argument("--fixture-out", default="backend/db/fixtures/byz_calc_recipes.json")
    parser.add_argument("--report-out", default="docs/byz-metraj-import-veri-kalitesi-raporu.md")
    args = parser.parse_args()

    data = extract_literal_assignments(
        args.byz_file,
        {"groups_to_seed", "group_assignments", "categories_to_seed", "recipes_per_category"},
    )
    fixture = build_fixture(data)

    os.makedirs(os.path.dirname(args.fixture_out), exist_ok=True)
    with open(args.fixture_out, "w", encoding="utf-8") as f:
        json.dump(fixture, f, ensure_ascii=False, indent=2, sort_keys=False)

    report = data_quality_report(fixture)
    os.makedirs(os.path.dirname(args.report_out), exist_ok=True)
    with open(args.report_out, "w", encoding="utf-8") as f:
        f.write(report)

    print(f"Fixture yazıldı: {args.fixture_out} "
          f"({len(fixture['groups'])} grup, {len(fixture['categories'])} kategori, {len(fixture['recipe_items'])} kalem)")
    print(f"Veri kalitesi raporu yazıldı: {args.report_out}")


if __name__ == "__main__":
    main()
