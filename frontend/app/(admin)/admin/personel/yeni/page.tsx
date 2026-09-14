"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiClient, ApiError } from "@/lib/api";
import type { Employee } from "@/lib/types";

export default function YeniPersonelPage() {
  const router = useRouter();
  const [form, setForm] = useState({
    full_name: "",
    phone: "",
    position: "",
    daily_wage: "",
    salary: "",
    start_date: "",
    description: "",
  });
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      await apiClient<Employee>("/api/v1/employees", {
        method: "POST",
        body: JSON.stringify({
          full_name: form.full_name,
          phone: form.phone,
          position: form.position,
          daily_wage: form.daily_wage ? parseFloat(form.daily_wage) : null,
          salary: form.salary ? parseFloat(form.salary) : null,
          start_date: form.start_date || null,
          description: form.description,
        }),
      });
      router.push("/admin/personel");
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
      setLoading(false);
    }
  }

  return (
    <>
      <PageHeader title="Yeni Personel" />
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
              <div className="grid grid-cols-2 gap-3">
                <Input
                  label="Telefon"
                  value={form.phone}
                  onChange={(e) => setForm({ ...form, phone: e.target.value })}
                />
                <Input
                  label="Görev"
                  value={form.position}
                  onChange={(e) => setForm({ ...form, position: e.target.value })}
                />
              </div>
              <div className="grid grid-cols-2 gap-3">
                <Input
                  label="Günlük Yevmiye"
                  type="number"
                  step="0.01"
                  min={0}
                  value={form.daily_wage}
                  onChange={(e) => setForm({ ...form, daily_wage: e.target.value })}
                />
                <Input
                  label="Aylık Maaş"
                  type="number"
                  step="0.01"
                  min={0}
                  value={form.salary}
                  onChange={(e) => setForm({ ...form, salary: e.target.value })}
                />
              </div>
              <Input
                label="İşe Başlama Tarihi"
                type="date"
                value={form.start_date}
                onChange={(e) => setForm({ ...form, start_date: e.target.value })}
              />
              <Input
                label="Açıklama"
                value={form.description}
                onChange={(e) => setForm({ ...form, description: e.target.value })}
              />
              {error && <p className="text-xs text-danger">{error}</p>}
              <Button type="submit" disabled={loading}>
                {loading ? "Kaydediliyor…" : "Personel Ekle"}
              </Button>
            </form>
          </CardBody>
        </Card>
      </div>
    </>
  );
}
