"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiClient, ApiError } from "@/lib/api";
import type { Role, User } from "@/lib/types";

export default function YeniKullaniciPage() {
  const router = useRouter();
  const [form, setForm] = useState({
    username: "",
    password: "",
    full_name: "",
    role: "kullanici" as Role,
  });
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      await apiClient<User>("/api/v1/users", {
        method: "POST",
        body: JSON.stringify(form),
      });
      router.push("/admin/kullanicilar");
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setLoading(false);
    }
  }

  return (
    <>
      <PageHeader title="Yeni Kullanıcı" />
      <div className="p-8">
        <Card className="max-w-md">
          <CardBody>
            <form onSubmit={handleSubmit} className="flex flex-col gap-4">
              <Input
                label="Ad Soyad"
                required
                value={form.full_name}
                onChange={(e) => setForm({ ...form, full_name: e.target.value })}
              />
              <Input
                label="Kullanıcı Adı"
                required
                value={form.username}
                onChange={(e) => setForm({ ...form, username: e.target.value })}
              />
              <Input
                label="Şifre"
                type="password"
                required
                minLength={8}
                value={form.password}
                onChange={(e) => setForm({ ...form, password: e.target.value })}
              />
              <div className="flex flex-col gap-1.5">
                <label className="text-xs font-semibold uppercase tracking-widest text-text-muted">
                  Rol
                </label>
                <select
                  value={form.role}
                  onChange={(e) => setForm({ ...form, role: e.target.value as Role })}
                  className="rounded-md border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus:border-gold"
                >
                  <option value="kullanici">Kullanıcı</option>
                  <option value="admin">Yönetici</option>
                </select>
              </div>
              {error && <p className="text-xs text-danger">{error}</p>}
              <Button type="submit" disabled={loading}>
                {loading ? "Kaydediliyor…" : "Kullanıcı Oluştur"}
              </Button>
            </form>
          </CardBody>
        </Card>
      </div>
    </>
  );
}
