"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import type { Offer, OfferShareLink } from "@/lib/types";

type ExpiresIn = "7d" | "30d" | "never";

const EXPIRY_OPTIONS: { value: ExpiresIn; label: string }[] = [
  { value: "7d", label: "7 gün" },
  { value: "30d", label: "30 gün" },
  { value: "never", label: "Süresiz" },
];

const selectClass =
  "rounded-md border border-border bg-surface px-3 py-2 text-sm text-text outline-none focus:border-gold disabled:opacity-50";

export function ShareOfferCard({
  offer,
  links,
  revisionNoById,
}: {
  offer: Offer;
  links: OfferShareLink[];
  revisionNoById: Record<string, number>;
}) {
  const router = useRouter();
  const [expiresIn, setExpiresIn] = useState<ExpiresIn>("never");
  const [creating, setCreating] = useState(false);
  const [revokingId, setRevokingId] = useState<string | null>(null);
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const [showMailForm, setShowMailForm] = useState(false);
  const [sending, setSending] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [mail, setMail] = useState({
    to: offer.customer_email,
    subject: `Teklifiniz: ${offer.offer_no}`,
    message: "",
  });

  const activeLinks = links.filter((l) => l.is_active);
  const pastLinks = links.filter((l) => !l.is_active);

  function shareUrl(token: string) {
    return `${window.location.origin}/paylas/${token}`;
  }

  async function handleCreate() {
    setCreating(true);
    setMessage(null);
    try {
      await apiClient(`/api/v1/offers/${offer.id}/share-links`, {
        method: "POST",
        body: JSON.stringify({ expires_in: expiresIn }),
      });
      router.refresh();
    } catch (err) {
      setMessage(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setCreating(false);
    }
  }

  async function handleCopy(link: OfferShareLink) {
    try {
      await navigator.clipboard.writeText(shareUrl(link.token));
      setCopiedId(link.id);
      setTimeout(() => setCopiedId(null), 2000);
    } catch {
      setMessage("Link kopyalanamadı, tarayıcı izin vermiyor olabilir.");
    }
  }

  async function handleRevoke(link: OfferShareLink) {
    if (!confirm("Bu paylaşım linki iptal edilsin mi? Müşteri bu linkten teklifi artık göremez.")) return;
    setRevokingId(link.id);
    setMessage(null);
    try {
      await apiClient(`/api/v1/offers/${offer.id}/share-links/${link.id}`, { method: "DELETE" });
      router.refresh();
    } catch (err) {
      setMessage(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setRevokingId(null);
    }
  }

  async function handleSendMail(e: FormEvent) {
    e.preventDefault();
    setSending(true);
    setMessage(null);
    try {
      await apiClient(`/api/v1/offers/${offer.id}/send-email`, {
        method: "POST",
        body: JSON.stringify(mail),
      });
      setMessage("Mail gönderildi.");
      setShowMailForm(false);
      router.refresh();
    } catch (err) {
      setMessage(err instanceof ApiError ? err.message : "Bağlantı hatası");
      // Gönderim başarısız olsa bile sunucu tarafında kalıcı kayıtlar
      // oluşmuş olabilir (paylaşım linki ve "başarısız" mail logu), bu
      // yüzden hata durumunda da tazeliyoruz -- aksi halde ekran
      // gerçekte var olan bir linki yokmuş gibi gösterirdi.
      router.refresh();
    } finally {
      setSending(false);
    }
  }

  function revisionLabel(link: OfferShareLink) {
    const no = revisionNoById[link.revision_id];
    return no === undefined ? "Revizyon ?" : `Revizyon ${no}`;
  }

  function linkStateLabel(link: OfferShareLink) {
    if (link.revoked_at) return `İptal edildi · ${new Date(link.revoked_at).toLocaleString("tr-TR")}`;
    if (link.expires_at && new Date(link.expires_at) < new Date()) {
      return `Süresi doldu · ${new Date(link.expires_at).toLocaleString("tr-TR")}`;
    }
    return "";
  }

  return (
    <Card>
      <CardHeader>Müşteriyle Paylaş</CardHeader>
      <CardBody className="flex flex-col gap-4">
        {activeLinks.length === 0 ? (
          <p className="text-sm text-text-muted">Henüz aktif bir paylaşım linki yok.</p>
        ) : (
          <div className="flex flex-col gap-3">
            {activeLinks.map((link) => (
              <div key={link.id} className="rounded-md border border-border p-3 text-sm">
                <div className="flex items-center justify-between gap-2">
                  <span className="font-medium">
                    {revisionLabel(link)}
                    {revisionNoById[link.revision_id] === offer.revision_no && (
                      <span className="ml-2 text-xs text-gold">(güncel)</span>
                    )}
                  </span>
                  <span className="text-xs text-success">Aktif</span>
                </div>
                <div className="mt-1 text-xs text-text-muted">
                  Oluşturuldu: {new Date(link.created_at).toLocaleString("tr-TR")}
                </div>
                <div className="text-xs text-text-muted">
                  Sona erme:{" "}
                  {link.expires_at ? new Date(link.expires_at).toLocaleString("tr-TR") : "Süresiz"}
                </div>
                <div className="mt-2 flex gap-2">
                  <Button type="button" variant="secondary" onClick={() => handleCopy(link)}>
                    {copiedId === link.id ? "Kopyalandı ✓" : "Kopyala"}
                  </Button>
                  <Button
                    type="button"
                    variant="danger"
                    disabled={revokingId === link.id}
                    onClick={() => handleRevoke(link)}
                  >
                    {revokingId === link.id ? "İptal ediliyor…" : "İptal Et"}
                  </Button>
                </div>
              </div>
            ))}
          </div>
        )}

        <div className="flex flex-wrap items-center gap-2 border-t border-border pt-3">
          <select
            value={expiresIn}
            disabled={creating}
            onChange={(e) => setExpiresIn(e.target.value as ExpiresIn)}
            className={selectClass}
            aria-label="Link süresi"
          >
            {EXPIRY_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </select>
          <Button type="button" variant="secondary" disabled={creating} onClick={handleCreate}>
            {creating ? "Oluşturuluyor…" : activeLinks.length === 0 ? "Link Oluştur" : "Yeni Link Oluştur"}
          </Button>
          <Button type="button" onClick={() => setShowMailForm((v) => !v)}>
            Mail Gönder
          </Button>
        </div>

        {showMailForm && (
          <form onSubmit={handleSendMail} className="flex flex-col gap-3 border-t border-border pt-3">
            <Input
              label="Kime"
              type="email"
              required
              value={mail.to}
              onChange={(e) => setMail({ ...mail, to: e.target.value })}
            />
            <Input
              label="Konu"
              value={mail.subject}
              onChange={(e) => setMail({ ...mail, subject: e.target.value })}
            />
            <Input
              label="Mesaj (opsiyonel)"
              value={mail.message}
              onChange={(e) => setMail({ ...mail, message: e.target.value })}
              placeholder="Boş bırakılırsa varsayılan mesaj kullanılır"
            />
            <p className="text-xs text-text-muted">
              Mail, güncel revizyonun paylaşım linkini içerir; aktif link yoksa süresiz bir link
              otomatik oluşturulur.
            </p>
            <Button type="submit" disabled={sending}>
              {sending ? "Gönderiliyor…" : "Gönder"}
            </Button>
          </form>
        )}

        {pastLinks.length > 0 && (
          <details className="border-t border-border pt-3 text-xs text-text-muted">
            <summary className="cursor-pointer">Geçmiş linkler ({pastLinks.length})</summary>
            <ul className="mt-2 flex flex-col gap-1">
              {pastLinks.map((link) => (
                <li key={link.id}>
                  {revisionLabel(link)} · {linkStateLabel(link)}
                </li>
              ))}
            </ul>
          </details>
        )}

        {message && <p className="text-xs text-text-muted">{message}</p>}
      </CardBody>
    </Card>
  );
}
