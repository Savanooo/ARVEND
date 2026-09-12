import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import type { OfferEmailLog, OfferEvent, OfferEventType } from "@/lib/types";

function shortStamp(iso: string) {
  const d = new Date(iso);
  const dd = String(d.getDate()).padStart(2, "0");
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const hh = String(d.getHours()).padStart(2, "0");
  const mi = String(d.getMinutes()).padStart(2, "0");
  return `${dd}.${mm} ${hh}:${mi}`;
}

// Türkçe belirtme eki sayının OKUNUŞUNA göre değişir (0'ı, 1'i, 2'yi,
// 3'ü...). 10'un katlarında okunuş "on/yirmi/otuz..." olduğu için son
// basamak tablosu yanlış sonuç verir; onlar ayrıca ele alınır.
const ACC_BY_LAST_DIGIT = ["ı", "i", "yi", "ü", "ü", "i", "yı", "yi", "i", "u"];
const ACC_BY_TENS = ["", "u", "yi", "u", "ı", "yi", "ı", "i", "i", "ı"];

function accusative(n: number): string {
  if (n >= 10 && n < 100 && n % 10 === 0) return ACC_BY_TENS[n / 10];
  return ACC_BY_LAST_DIGIT[n % 10];
}

// revision_id -> revision_no eşlemesi bilinmiyorsa (ör. olay revizyondan
// bağımsızsa) "Revizyon ?" yerine metni revizyonsuz kurarız.
function label(e: OfferEvent, revNo: number | undefined): string {
  const rev = revNo === undefined ? "" : `Revizyon ${revNo}`;
  const revAcc = revNo === undefined ? "" : `${rev}'${accusative(revNo)}`;
  const map: Record<OfferEventType, string> = {
    offer_created: "Teklif oluşturuldu",
    offer_updated: rev ? `${rev} düzenlendi` : "Teklif düzenlendi",
    revision_created: rev ? `${rev} oluşturuldu` : "Yeni revizyon oluşturuldu",
    revision_sent: rev ? `${rev} müşteriye gönderildi` : "Teklif müşteriye gönderildi",
    share_link_created: rev ? `${rev} için paylaşım linki oluşturuldu` : "Paylaşım linki oluşturuldu",
    share_link_revoked:
      e.metadata?.reason === "revision_sent"
        ? rev
          ? `${rev} linki, yeni revizyon gönderildiği için iptal edildi`
          : "Eski paylaşım linki iptal edildi"
        : rev
          ? `${rev} paylaşım linki iptal edildi`
          : "Paylaşım linki iptal edildi",
    customer_viewed: rev ? `Müşteri ${revAcc} görüntüledi` : "Müşteri teklifi görüntüledi",
    customer_accepted: rev ? `Müşteri ${revAcc} kabul etti` : "Müşteri teklifi kabul etti",
    customer_rejected: rev ? `Müşteri ${revAcc} reddetti` : "Müşteri teklifi reddetti",
    email_sent: rev ? `${rev} e-posta ile gönderildi` : "E-posta gönderildi",
    email_failed: rev ? `${rev} e-postası gönderilemedi` : "E-posta gönderilemedi",
    offer_cancelled: "Teklif arşivlendi / iptal edildi",
  };
  return map[e.event_type] ?? e.event_type;
}

const TONE: Partial<Record<OfferEventType, string>> = {
  customer_accepted: "text-success",
  customer_rejected: "text-danger",
  email_failed: "text-danger",
  share_link_revoked: "text-text-muted",
  customer_viewed: "text-gold",
};

export function ActivityTimeline({
  events,
  emailLogs,
  revisionNoById,
}: {
  events: OfferEvent[];
  emailLogs: OfferEmailLog[];
  revisionNoById: Record<string, number>;
}) {
  const views = events.filter((e) => e.event_type === "customer_viewed");
  const firstView = views[0];
  const lastView = views[views.length - 1];

  return (
    <>
      <Card className="h-fit">
        <CardHeader>Aktivite / Zaman Çizelgesi</CardHeader>
        <CardBody className="flex flex-col gap-3 text-sm">
          {views.length > 0 && (
            <div className="rounded-md bg-surface-hover px-3 py-2 text-xs text-text-muted">
              <span className="font-medium text-text">{views.length}</span> görüntülenme · ilk{" "}
              {new Date(firstView.created_at).toLocaleString("tr-TR")} · son{" "}
              {new Date(lastView.created_at).toLocaleString("tr-TR")}
            </div>
          )}
          {events.length === 0 ? (
            <p className="text-text-muted">Henüz kayıtlı bir olay yok.</p>
          ) : (
            <ol className="flex flex-col gap-1.5">
              {events.map((e) => {
                const revNo = e.revision_id ? revisionNoById[e.revision_id] : undefined;
                return (
                  <li key={e.id} className="flex gap-3">
                    <span className="w-24 shrink-0 tabular-nums text-text-muted">
                      {shortStamp(e.created_at)}
                    </span>
                    <span className="text-text-muted">—</span>
                    <span className={TONE[e.event_type] ?? ""}>{label(e, revNo)}</span>
                  </li>
                );
              })}
            </ol>
          )}
        </CardBody>
      </Card>

      {emailLogs.length > 0 && (
        <Card className="h-fit">
          <CardHeader>Mail Geçmişi</CardHeader>
          <CardBody className="flex flex-col gap-2 text-sm">
            {emailLogs.map((l) => {
              const revNo = revisionNoById[l.revision_id];
              return (
                <div key={l.id} className="border-b border-border pb-2 last:border-b-0 last:pb-0">
                  <div className="flex items-center justify-between gap-2">
                    <span className="font-medium">{l.recipient}</span>
                    <span className={l.status === "sent" ? "text-xs text-success" : "text-xs text-danger"}>
                      {l.status === "sent" ? "Gönderildi" : "Başarısız"}
                    </span>
                  </div>
                  <div className="text-xs text-text-muted">
                    {l.subject}
                    {revNo !== undefined && ` · Revizyon ${revNo}`} ·{" "}
                    {new Date(l.sent_at).toLocaleString("tr-TR")}
                  </div>
                  {l.error_message && <div className="text-xs text-danger">{l.error_message}</div>}
                </div>
              );
            })}
          </CardBody>
        </Card>
      )}
    </>
  );
}
