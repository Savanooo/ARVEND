"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { apiClient, ApiError } from "@/lib/api";
import type { Offer } from "@/lib/types";

export function ShareOfferCard({ offer }: { offer: Offer }) {
  const router = useRouter();
  const [showMailForm, setShowMailForm] = useState(false);
  const [copied, setCopied] = useState(false);
  const [sending, setSending] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [mail, setMail] = useState({
    to: offer.customer_email,
    subject: `Teklifiniz: ${offer.offer_no}`,
    message: "",
  });

  function shareUrl() {
    return `${window.location.origin}/paylas/${offer.share_token}`;
  }

  async function handleCopyLink() {
    try {
      await navigator.clipboard.writeText(shareUrl());
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      setMessage("Link kopyalanamadı, tarayıcı izin vermiyor olabilir.");
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
    } finally {
      setSending(false);
    }
  }

  return (
    <Card>
      <CardHeader>Müşteriyle Paylaş</CardHeader>
      <CardBody className="flex flex-col gap-3">
        <div className="flex gap-2">
          <Button type="button" variant="secondary" onClick={handleCopyLink}>
            {copied ? "Kopyalandı ✓" : "Linki Kopyala"}
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
            <Button type="submit" disabled={sending}>
              {sending ? "Gönderiliyor…" : "Gönder"}
            </Button>
          </form>
        )}

        {message && <p className="text-xs text-text-muted">{message}</p>}
      </CardBody>
    </Card>
  );
}
