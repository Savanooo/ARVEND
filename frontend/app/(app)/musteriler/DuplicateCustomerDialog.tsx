"use client";

import { Button } from "@/components/ui/Button";
import { Modal } from "@/components/ui/Modal";
import { duplicateCustomerIntro, type DuplicateCustomer } from "@/lib/customers";

export type DuplicateCustomerChoice = "cancel" | "open" | "saveAnyway";

// 409 duplicate_customer penceresi (mobil showDuplicateCustomerDialog ile
// aynı): çakışan müşteriyi gösterir, "Vazgeç / Mevcut müşteriyi aç / Yine de
// kaydet" sorar. Oluşturma ve düzenleme formları aynı pencereyi kullanır --
// aynı çakışma iki ekranda iki farklı biçimde anlatılmasın. Sessizce
// reddetmek iki şubeli firmayı kaydedilemez bırakırdı; sessizce kaydetmek
// aynı müşterinin farklı yazımlarla tekrar açılmasına yol açardı.
export function DuplicateCustomerDialog({
  duplicate,
  onChoice,
}: {
  duplicate: DuplicateCustomer | null;
  onChoice: (choice: DuplicateCustomerChoice) => void;
}) {
  return (
    <Modal
      open={duplicate !== null}
      onClose={() => onChoice("cancel")}
      title="Bu müşteri zaten kayıtlı olabilir"
      footer={
        <>
          <Button type="button" variant="ghost" onClick={() => onChoice("cancel")}>
            Vazgeç
          </Button>
          <Button type="button" variant="secondary" onClick={() => onChoice("open")}>
            Mevcut müşteriyi aç
          </Button>
          <Button type="button" onClick={() => onChoice("saveAnyway")}>
            Yine de kaydet
          </Button>
        </>
      }
    >
      {duplicate && (
        <div className="flex flex-col gap-2">
          <p>{duplicateCustomerIntro(duplicate.field)}</p>
          <p className="font-semibold">{duplicate.isActive ? duplicate.name : `${duplicate.name} (arşivde)`}</p>
          <p className="text-xs text-text-muted">
            Aynı firmanın ayrı bir kaydıysa (ör. ikinci şube) yine de kaydedebilirsiniz.
          </p>
        </div>
      )}
    </Modal>
  );
}
