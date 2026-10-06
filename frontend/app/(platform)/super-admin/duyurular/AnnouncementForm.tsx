"use client";

import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Textarea } from "@/components/ui/Textarea";
import { apiClient, ApiError } from "@/lib/api";

type Org = { id: string; name: string };

export function AnnouncementForm({ organizations }: { organizations: Org[] }) {
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [allFirms, setAllFirms] = useState(true);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [confirming, setConfirming] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<string | null>(null);

  const targetCount = allFirms ? organizations.length : selected.size;

  function toggle(id: string) {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setResult(null);
    if (!title.trim() || !body.trim()) {
      setError("Başlık ve metin zorunlu.");
      return;
    }
    if (targetCount === 0) {
      setError("En az bir firma seç.");
      return;
    }
    setConfirming(true);
  }

  async function send() {
    setLoading(true);
    setError(null);
    try {
      const res = await apiClient<{ recipients: number; push_enabled: boolean }>("/api/v1/platform/announcements", {
        method: "POST",
        body: JSON.stringify({
          title: title.trim(),
          body: body.trim(),
          organization_ids: allFirms ? [] : [...selected],
        }),
      });
      setResult(
        `Duyuru ${res.recipients} kişiye gönderildi.` +
          (res.push_enabled ? "" : " (Sunucuda telefon bildirimi kapalı; yalnızca uygulama içinde görünür.)")
      );
      setTitle("");
      setBody("");
      setConfirming(false);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setLoading(false);
    }
  }

  return (
    <Card className="max-w-2xl">
      <CardBody>
        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <Input
            label="Başlık"
            name="duyuru-baslik"
            value={title}
            maxLength={120}
            onChange={(e) => {
              setTitle(e.target.value);
              setConfirming(false);
            }}
            placeholder="ör. Bu gece kısa bakım"
            required
          />
          <Textarea
            label="Metin"
            name="duyuru-metin"
            value={body}
            maxLength={500}
            rows={5}
            onChange={(e) => {
              setBody(e.target.value);
              setConfirming(false);
            }}
            required
          />
          <fieldset className="flex flex-col gap-2">
            <legend className="mb-1 text-xs font-semibold uppercase tracking-widest text-text-muted">Kime</legend>
            <label className="flex items-center gap-2 text-sm">
              <input type="radio" checked={allFirms} onChange={() => setAllFirms(true)} />
              Tüm aktif firmalar ({organizations.length})
            </label>
            <label className="flex items-center gap-2 text-sm">
              <input type="radio" checked={!allFirms} onChange={() => setAllFirms(false)} />
              Seçili firmalar
            </label>
            {!allFirms && (
              <div className="ml-6 flex max-h-60 flex-col gap-1 overflow-y-auto rounded-md border border-border p-2">
                {organizations.map((o) => (
                  <label key={o.id} className="flex items-center gap-2 text-sm">
                    <input type="checkbox" checked={selected.has(o.id)} onChange={() => toggle(o.id)} />
                    {o.name}
                  </label>
                ))}
              </div>
            )}
          </fieldset>

          {error && <p className="text-sm text-danger">{error}</p>}
          {result && <p className="text-sm text-success">{result}</p>}

          {confirming ? (
            <div className="flex flex-wrap items-center gap-2 rounded-md border border-gold/40 bg-gold-soft p-3 text-sm">
              <span className="flex-1">
                {targetCount} firmadaki bütün aktif kullanıcılara gönderilecek. Emin misin?
              </span>
              <Button type="button" variant="secondary" onClick={() => setConfirming(false)} disabled={loading}>
                Vazgeç
              </Button>
              <Button type="button" onClick={send} loading={loading}>
                Gönder
              </Button>
            </div>
          ) : (
            <div>
              <Button type="submit">Duyuruyu Gönder</Button>
            </div>
          )}
        </form>
      </CardBody>
    </Card>
  );
}
