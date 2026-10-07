"use client";

import { useEffect, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { Modal } from "@/components/ui/Modal";
import { Select } from "@/components/ui/Select";
import { Table, Td, Th, Tr } from "@/components/ui/Table";
import { apiClient, ApiError } from "@/lib/api";
import { formatTL } from "@/lib/format";
import type { CalcGroupWithCategories, CalcRunResult, CalcSnapshot } from "@/lib/types";

// MetrajOfferItemDraft, bu panelin "Teklife Ekle" ile ürettiği satırlardır
// -- OfferForm (ve ileride Proje/Ek İş formları) bunları kendi kalem
// listesine ekler. calc_snapshot, hesap ANINDA dondurulur; kategori/reçete
// sonradan değişse/silinse bile bu değerler BİR DAHA GÜNCELLENMEZ.
export interface MetrajOfferItemDraft {
  product_id: string | null;
  product_name: string;
  quantity: number;
  unit_price: number;
  unit: string;
  section_label: string;
  calc_category_id: string;
  calc_snapshot: CalcSnapshot;
}

type Mode = "olcu" | "alan";

// Bu bileşen, teklif/proje/ek iş formlarından bağımsızdır (yalnızca
// onAddItems callback'i ile dışarıya veri verir) -- BYZ'deki gibi tek bir
// ekrana gömülü değildir, aynı panel ileride Proje ve Ek İş formlarından
// da (kullanıcı talimatı) çağrılabilir.
export function MetrajHesaplaPanel({
  open,
  onClose,
  onAddItems,
}: {
  open: boolean;
  onClose: () => void;
  onAddItems: (items: MetrajOfferItemDraft[]) => void;
}) {
  const [groups, setGroups] = useState<CalcGroupWithCategories[]>([]);
  const [groupsLoading, setGroupsLoading] = useState(false);
  const [groupId, setGroupId] = useState("");
  const [categoryId, setCategoryId] = useState("");
  const [mode, setMode] = useState<Mode>("olcu");
  const [width, setWidth] = useState("");
  const [height, setHeight] = useState("");
  const [area, setArea] = useState("");
  // Çevre (m): çevreye bağlı reçete kalemleri (perimeter_based) için.
  // En × Boy modunda boşsa backend en/boydan hesaplar; Doğrudan Alan
  // modunda girilmezse o kalemler 0 çıkar ve teklife eklenmez (mobil ile
  // aynı alan).
  const [perimeter, setPerimeter] = useState("");
  const [pitchDeg, setPitchDeg] = useState("");
  const [sectionLabel, setSectionLabel] = useState("");
  const [result, setResult] = useState<CalcRunResult | null>(null);
  const [calculating, setCalculating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Panel her AÇILIŞTA grupları yeniden çeker (bir öncekinden bu yana
  // admin yeni grup/kategori eklemiş olabilir) -- bu meşru bir ağ
  // efektidir (ChangeOrderSections.tsx'teki fetchDetail() ile aynı
  // gerekçe): "effect içinde setState" kuralı bilinçli olarak devre
  // dışı bırakılır.
  function loadGroups() {
    setGroupsLoading(true);
    apiClient<{ groups: CalcGroupWithCategories[] }>("/api/v1/calculations/categories")
      .then((res) => setGroups(res.groups))
      .catch(() => setError("Hesaplama grupları alınamadı"))
      .finally(() => setGroupsLoading(false));
  }

  useEffect(() => {
    if (!open) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect
    loadGroups();
  }, [open]);

  // Panel her kapanışta tamamen sıfırlanır -- bir sonraki açılışta önceki
  // teklifin/hesabın kalıntısı görünmesin. Dışarıdan (open prop'u)
  // tetiklenen bir senkronizasyon olduğu için aynı gerekçeyle devre dışı.
  function resetForm() {
    setGroupId("");
    setCategoryId("");
    setMode("olcu");
    setWidth("");
    setHeight("");
    setArea("");
    setPerimeter("");
    setPitchDeg("");
    setSectionLabel("");
    setResult(null);
    setError(null);
  }

  useEffect(() => {
    if (open) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect
    resetForm();
  }, [open]);

  const selectedGroup = groups.find((g) => g.id === groupId);
  const categories = selectedGroup?.categories ?? [];
  const selectedCategory = categories.find((c) => c.id === categoryId);

  // Çatı eğimi alanı yalnızca grup adı "çatı" içeriyorsa gösterilir --
  // bu SALT bir arayüz kolaylığıdır (BYZ'deki sabit kodlu
  // 'cati-hesaplamalari' slug kontrolünün YERİNE GEÇMEZ): backend
  // pitch_deg'i hangi kategori olursa olsun kabul eder, burada yalnızca
  // alanı gereksiz yere göstermemek için bir ön izleme sezgiselidir.
  const showPitch = (selectedGroup?.name ?? "").toLocaleLowerCase("tr-TR").includes("çatı");

  function handleGroupChange(id: string) {
    setGroupId(id);
    setCategoryId("");
    setResult(null);
  }

  async function handleCalculate() {
    if (!categoryId) {
      setError("Bir hesaplama türü seçin.");
      return;
    }
    if (mode === "alan" && !area.trim()) {
      setError("Alan (m²) girin.");
      return;
    }
    if (mode === "olcu" && (!width.trim() || !height.trim())) {
      setError("En ve Boy girin.");
      return;
    }
    const perimeterValue = perimeter.trim().replace(",", ".");
    if (perimeterValue && !(Number(perimeterValue) > 0)) {
      setError("Çevre (m) sıfırdan büyük bir sayı olmalı.");
      return;
    }
    setCalculating(true);
    setError(null);
    try {
      const body: Record<string, string> = { category_id: categoryId };
      if (mode === "alan") {
        body.area = area.trim().replace(",", ".");
      } else {
        body.width = width.trim().replace(",", ".");
        body.height = height.trim().replace(",", ".");
      }
      if (perimeterValue) body.perimeter = perimeterValue;
      if (showPitch && pitchDeg.trim()) body.pitch_deg = pitchDeg.trim().replace(",", ".");
      const res = await apiClient<CalcRunResult>("/api/v1/calculations/run", {
        method: "POST",
        body: JSON.stringify(body),
      });
      setResult(res);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Hesaplama başarısız oldu");
      setResult(null);
    } finally {
      setCalculating(false);
    }
  }

  function handleAddToOffer() {
    if (!result) return;
    const label = sectionLabel.trim() || result.category.name;
    const items: MetrajOfferItemDraft[] = result.items
      .filter((it) => parseFloat(it.quantity.replace(",", ".")) > 0)
      .map((it) => ({
        product_id: it.product_id,
        product_name: it.material_name,
        quantity: parseFloat(it.quantity.replace(",", ".")) || 0,
        unit_price: parseFloat(it.unit_price.replace(",", ".")) || 0,
        unit: it.unit,
        section_label: label,
        calc_category_id: result.category.id,
        calc_snapshot: {
          area: result.input.effective_area,
          perimeter: result.input.perimeter,
          pitch_deg: showPitch && pitchDeg.trim() ? pitchDeg.trim() : null,
          recipe_factor: it.factor,
          waste_percent: it.waste_percent,
          rounding_type: it.rounding_type,
          price_at_calc: it.unit_price,
          category_name: result.category.name,
          group_name: selectedGroup?.name,
        },
      }));
    if (items.length === 0) return;
    onAddItems(items);
    onClose();
  }

  return (
    <Modal open={open} onClose={onClose} title="Metraj Hesapla" widthClassName="max-w-4xl">
      <div className="flex flex-col gap-5">
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <Select
            label="Hesaplama Grubu"
            value={groupId}
            onChange={(e) => handleGroupChange(e.target.value)}
            disabled={groupsLoading}
          >
            <option value="">{groupsLoading ? "Yükleniyor…" : "Seçin"}</option>
            {groups.map((g) => (
              <option key={g.id} value={g.id}>
                {g.name}
              </option>
            ))}
          </Select>
          <Select
            label="Hesaplama Türü"
            value={categoryId}
            onChange={(e) => {
              setCategoryId(e.target.value);
              setResult(null);
            }}
            disabled={!groupId}
          >
            <option value="">{groupId ? "Seçin" : "Önce grup seçin"}</option>
            {categories.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </Select>
        </div>

        {selectedCategory?.description && (
          <p className="text-xs text-text-muted">{selectedCategory.description}</p>
        )}

        <div className="flex flex-col gap-3 rounded-md border border-border bg-surface-hover/30 p-4">
          <div className="flex gap-2">
            <button
              type="button"
              onClick={() => setMode("olcu")}
              className={`rounded-md px-3 py-1.5 text-xs font-semibold uppercase tracking-widest ${
                mode === "olcu" ? "bg-gold text-text" : "text-text-muted hover:text-text"
              }`}
            >
              En × Boy
            </button>
            <button
              type="button"
              onClick={() => setMode("alan")}
              className={`rounded-md px-3 py-1.5 text-xs font-semibold uppercase tracking-widest ${
                mode === "alan" ? "bg-gold text-text" : "text-text-muted hover:text-text"
              }`}
            >
              Doğrudan Alan
            </button>
          </div>

          <div className="grid grid-cols-2 gap-4 sm:grid-cols-4">
            {mode === "olcu" ? (
              <>
                <Input
                  label="En (m)"
                  type="number"
                  step="0.01"
                  value={width}
                  onChange={(e) => setWidth(e.target.value)}
                />
                <Input
                  label="Boy (m)"
                  type="number"
                  step="0.01"
                  value={height}
                  onChange={(e) => setHeight(e.target.value)}
                />
              </>
            ) : (
              <Input
                label="Alan (m²)"
                type="number"
                step="0.01"
                value={area}
                onChange={(e) => setArea(e.target.value)}
              />
            )}
            <Input
              label="Çevre (m)"
              type="number"
              step="0.01"
              min={0}
              placeholder={mode === "olcu" ? "Boşsa En × Boy'dan" : "opsiyonel"}
              value={perimeter}
              onChange={(e) => setPerimeter(e.target.value)}
            />
            {showPitch && (
              <Input
                label="Çatı Eğimi (°)"
                type="number"
                step="0.1"
                min={0}
                max={89}
                value={pitchDeg}
                onChange={(e) => setPitchDeg(e.target.value)}
              />
            )}
            <Input
              label="Bölüm / Alan Adı"
              placeholder="ör. Salon Tavanı"
              value={sectionLabel}
              onChange={(e) => setSectionLabel(e.target.value)}
            />
          </div>

          <p className="text-xs text-text-muted">
            Çevre opsiyoneldir: En × Boy modunda boş bırakılırsa en ve boydan hesaplanır; Doğrudan
            Alan modunda çevreye bağlı kalemler (süpürgelik, köşe profili vb.) için girilmelidir.
          </p>

          <Button type="button" onClick={handleCalculate} loading={calculating} className="w-fit">
            Hesapla
          </Button>
        </div>

        {error && <p className="text-sm text-danger">{error}</p>}

        {result && (
          <div className="flex flex-col gap-3">
            <div className="flex flex-wrap items-baseline justify-between gap-2 text-sm text-text-muted">
              <span>
                {result.category.name} —{" "}
                {mode === "olcu" ? `${result.input.effective_area} m² (eğim sonrası)` : `${result.input.effective_area} m²`}
                {result.input.perimeter && ` · Çevre: ${result.input.perimeter} m`}
              </span>
            </div>

            {result.warnings.length > 0 && (
              <div className="flex flex-col gap-1 rounded-md border border-gold/40 bg-gold-soft/30 p-3 text-xs text-text">
                {result.warnings.map((w, i) => (
                  <p key={i}>⚠ {w.message}</p>
                ))}
              </div>
            )}

            <Table>
              <thead>
                <tr>
                  <Th>Malzeme</Th>
                  <Th className="text-right">Miktar</Th>
                  <Th>Birim</Th>
                  <Th className="text-right">Birim Fiyat</Th>
                  <Th className="text-right">Tutar</Th>
                </tr>
              </thead>
              <tbody>
                {result.items.map((it) => {
                  const hasWarning = result.warnings.some((w) => w.item_id === it.recipe_item_id);
                  return (
                    <Tr key={it.recipe_item_id}>
                      <Td className="font-medium">
                        {it.material_name}
                        {hasWarning && <span className="ml-1.5 text-gold">⚠</span>}
                      </Td>
                      <Td className="text-right">{it.quantity}</Td>
                      <Td className="text-text-muted">{it.unit}</Td>
                      <Td className="text-right">{formatTL(parseFloat(it.unit_price) || 0)}</Td>
                      <Td className="text-right font-medium">{formatTL(parseFloat(it.line_total) || 0)}</Td>
                    </Tr>
                  );
                })}
              </tbody>
            </Table>
            <div className="flex justify-end gap-2 text-sm">
              <span className="text-text-muted">Toplam</span>
              <span className="font-semibold">{formatTL(parseFloat(result.total_cost) || 0)}</span>
            </div>

            <Button type="button" onClick={handleAddToOffer} className="w-fit">
              Teklife Ekle
            </Button>
          </div>
        )}
      </div>
    </Modal>
  );
}
