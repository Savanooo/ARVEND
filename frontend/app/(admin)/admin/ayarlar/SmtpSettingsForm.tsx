"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import type { SmtpSettings } from "@/lib/types";

export function SmtpSettingsForm({ settings }: { settings: SmtpSettings }) {
  const router = useRouter();
  const [form, setForm] = useState({
    host: settings.host,
    port: settings.port || 587,
    username: settings.username,
    password: "",
    from_email: settings.from_email,
    from_name: settings.from_name,
    use_tls: settings.use_tls,
  });
  const [passwordSet, setPasswordSet] = useState(settings.password_set);
  const [saving, setSaving] = useState(false);
  const [testing, setTesting] = useState(false);
  const [testTo, setTestTo] = useState("");
  const [message, setMessage] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setSaving(true);
    setMessage(null);
    try {
      const updated = await apiClient<SmtpSettings>("/api/v1/settings/smtp", {
        method: "PUT",
        body: JSON.stringify({
          host: form.host,
          port: form.port,
          username: form.username,
          password: form.password || null,
          from_email: form.from_email,
          from_name: form.from_name,
          use_tls: form.use_tls,
        }),
      });
      setPasswordSet(updated.password_set);
      setForm({ ...form, password: "" });
      setMessage("Kaydedildi.");
      router.refresh();
    } catch (err) {
      setMessage(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setSaving(false);
    }
  }

  async function handleTest() {
    if (!testTo) {
      setMessage("Test e-postası için bir adres girin.");
      return;
    }
    setTesting(true);
    setMessage(null);
    try {
      await apiClient("/api/v1/settings/smtp/test", {
        method: "POST",
        body: JSON.stringify({ to: testTo }),
      });
      setMessage(`Test e-postası ${testTo} adresine gönderildi.`);
    } catch (err) {
      setMessage(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setTesting(false);
    }
  }

  return (
    <Card>
      <CardHeader>SMTP Ayarları</CardHeader>
      <CardBody>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <div className="grid grid-cols-2 gap-3">
            <Input
              label="Sunucu (Host)"
              required
              value={form.host}
              onChange={(e) => setForm({ ...form, host: e.target.value })}
            />
            <Input
              label="Port"
              type="number"
              required
              value={form.port}
              onChange={(e) => setForm({ ...form, port: parseInt(e.target.value) || 0 })}
            />
          </div>
          <Input
            label="Kullanıcı Adı"
            value={form.username}
            onChange={(e) => setForm({ ...form, username: e.target.value })}
          />
          <Input
            label={passwordSet ? "Şifre (değiştirmek için doldurun)" : "Şifre"}
            type="password"
            placeholder={passwordSet ? "••••••••" : ""}
            value={form.password}
            onChange={(e) => setForm({ ...form, password: e.target.value })}
          />
          <div className="grid grid-cols-2 gap-3">
            <Input
              label="Gönderen E-posta"
              type="email"
              required
              value={form.from_email}
              onChange={(e) => setForm({ ...form, from_email: e.target.value })}
            />
            <Input
              label="Gönderen Adı"
              value={form.from_name}
              onChange={(e) => setForm({ ...form, from_name: e.target.value })}
            />
          </div>
          <label className="flex items-center gap-2 text-sm text-text-muted">
            <input
              type="checkbox"
              checked={form.use_tls}
              onChange={(e) => setForm({ ...form, use_tls: e.target.checked })}
            />
            TLS/STARTTLS kullan
          </label>
          {message && <p className="text-xs text-text-muted">{message}</p>}
          <Button type="submit" disabled={saving}>
            {saving ? "Kaydediliyor…" : "Kaydet"}
          </Button>
        </form>

        <div className="mt-6 flex items-end gap-3 border-t border-border pt-6">
          <Input
            label="Test E-postası Gönder"
            type="email"
            placeholder="ornek@eposta.com"
            value={testTo}
            onChange={(e) => setTestTo(e.target.value)}
            className="flex-1"
          />
          <Button type="button" variant="secondary" disabled={testing} onClick={handleTest}>
            {testing ? "Gönderiliyor…" : "Test Et"}
          </Button>
        </div>
      </CardBody>
    </Card>
  );
}
