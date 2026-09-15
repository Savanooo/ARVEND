"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Select } from "@/components/ui/Select";
import { apiClient, ApiError } from "@/lib/api";
import type { Organization, Plan, User } from "@/lib/types";

function slugify(name: string): string {
  return name
    .toLocaleLowerCase("tr-TR")
    .replace(/ğ/g, "g")
    .replace(/ü/g, "u")
    .replace(/ş/g, "s")
    .replace(/ı/g, "i")
    .replace(/ö/g, "o")
    .replace(/ç/g, "c")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

// Owner, must_change_password=true ile provision edilir -- burada belirlenen
// şifre bir GEÇİCİ şifredir, Owner'a (Super Admin tarafından, bu ürünün
// kapsamında olmayan bir kanaldan -- ör. sözlü/harici) iletilir; ilk girişte
// zorunlu olarak değiştirilir (bkz. /sifre-belirle).
export function NewOrganizationForm({ plans }: { plans: Plan[] }) {
  const router = useRouter();
  const [name, setName] = useState("");
  const [slug, setSlug] = useState("");
  const [slugTouched, setSlugTouched] = useState(false);
  const [planCode, setPlanCode] = useState(plans.find((p) => p.code === "trial")?.code ?? plans[0]?.code ?? "");
  const [status, setStatus] = useState<"active" | "trial">("active");
  const [trialDays, setTrialDays] = useState(30);
  const [ownerUsername, setOwnerUsername] = useState("");
  const [ownerPassword, setOwnerPassword] = useState("");
  const [ownerFullName, setOwnerFullName] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  function handleNameChange(value: string) {
    setName(value);
    if (!slugTouched) setSlug(slugify(value));
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const result = await apiClient<{ organization: Organization; owner: User; calc_catalog_provisioned: boolean }>(
        "/api/v1/platform/organizations",
        {
          method: "POST",
          body: JSON.stringify({
            name,
            slug,
            plan_code: planCode,
            status,
            trial_days: status === "trial" ? trialDays : 0,
            owner_username: ownerUsername,
            owner_password: ownerPassword,
            owner_full_name: ownerFullName,
          }),
        }
      );
      router.push(`/super-admin/${result.organization.id}`);
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setLoading(false);
    }
  }

  return (
    <Card className="max-w-lg">
      <CardHeader>Firma Bilgileri</CardHeader>
      <CardBody>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <Input label="Firma Adı" required value={name} onChange={(e) => handleNameChange(e.target.value)} />
          <Input
            label="Slug"
            required
            value={slug}
            onChange={(e) => {
              setSlug(e.target.value);
              setSlugTouched(true);
            }}
          />
          <div className="grid grid-cols-2 gap-3">
            <Select label="Plan" value={planCode} onChange={(e) => setPlanCode(e.target.value)}>
              {plans.map((p) => (
                <option key={p.code} value={p.code}>
                  {p.name}
                </option>
              ))}
            </Select>
            <Select
              label="Durum"
              value={status}
              onChange={(e) => setStatus(e.target.value as "active" | "trial")}
            >
              <option value="active">Aktif</option>
              <option value="trial">Deneme</option>
            </Select>
          </div>
          {status === "trial" && (
            <Input
              label="Deneme Süresi (gün)"
              type="number"
              min={1}
              value={trialDays}
              onChange={(e) => setTrialDays(parseInt(e.target.value) || 0)}
            />
          )}

          <div className="border-t border-border pt-4">
            <p className="mb-3 text-xs font-semibold uppercase tracking-widest text-text-muted">
              İlk Kullanıcı (Owner)
            </p>
            <div className="flex flex-col gap-4">
              <Input
                label="Ad Soyad"
                required
                value={ownerFullName}
                onChange={(e) => setOwnerFullName(e.target.value)}
              />
              <Input
                label="Kullanıcı Adı"
                required
                value={ownerUsername}
                onChange={(e) => setOwnerUsername(e.target.value)}
              />
              <Input
                label="Geçici Şifre"
                type="password"
                required
                minLength={8}
                value={ownerPassword}
                onChange={(e) => setOwnerPassword(e.target.value)}
              />
              <p className="text-xs text-text-muted">
                Owner ilk girişte bu şifreyi değiştirmek zorunda kalır. Şifreyi Owner&apos;a güvenli bir
                kanaldan iletmeniz gerekir -- sistem otomatik e-posta göndermez.
              </p>
            </div>
          </div>

          {error && <p className="text-xs text-danger">{error}</p>}
          <Button type="submit" disabled={loading}>
            {loading ? "Oluşturuluyor…" : "Firma Oluştur"}
          </Button>
        </form>
      </CardBody>
    </Card>
  );
}
