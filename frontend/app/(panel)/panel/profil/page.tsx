"use client";

import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { PageHeader } from "@/components/layout/PageHeader";
import { apiClient, ApiError } from "@/lib/api";

export default function ProfilPage() {
  const [currentPassword, setCurrentPassword] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setLoading(true);
    setMessage(null);
    try {
      await apiClient("/api/v1/users/me/password", {
        method: "PATCH",
        body: JSON.stringify({
          current_password: currentPassword,
          new_password: newPassword,
        }),
      });
      setMessage("Şifreniz güncellendi.");
      setCurrentPassword("");
      setNewPassword("");
    } catch (err) {
      setMessage(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setLoading(false);
    }
  }

  return (
    <>
      <PageHeader title="Profilim" />
      <div className="p-8">
        <Card className="max-w-sm">
          <CardHeader>Şifre Değiştir</CardHeader>
          <CardBody>
            <form onSubmit={handleSubmit} className="flex flex-col gap-4">
              <Input
                label="Mevcut Şifre"
                type="password"
                value={currentPassword}
                onChange={(e) => setCurrentPassword(e.target.value)}
                required
              />
              <Input
                label="Yeni Şifre"
                type="password"
                minLength={8}
                value={newPassword}
                onChange={(e) => setNewPassword(e.target.value)}
                required
              />
              {message && <p className="text-xs text-text-muted">{message}</p>}
              <Button type="submit" disabled={loading}>
                {loading ? "Kaydediliyor…" : "Şifreyi Güncelle"}
              </Button>
            </form>
          </CardBody>
        </Card>
      </div>
    </>
  );
}
