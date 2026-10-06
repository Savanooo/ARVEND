"use client";

import { FormEvent, useState } from "react";

import { Button } from "./Button";
import { Modal } from "./Modal";
import { Textarea } from "./Textarea";

interface ReasonOptions {
  title: string;
  message?: string;
  label?: string;
  placeholder?: string;
  confirmLabel?: string;
  cancelLabel?: string;
  danger?: boolean;
  // Backend gerekçesiz reddediyorsa (sözleşme iptal/fesih, talep red/iptal,
  // sipariş iptali) onay düğmesi metin girilene kadar kapalı kalır.
  required?: boolean;
}

// useConfirmDialog'un gerekçe alanlı kardeşi; window.prompt()'un yerini
// alır. prompt() Vazgeç'te null döner ve çağrı yerleri bunu `?? ""` ile boş
// gerekçeye çevirip işlemi YİNE DE yapıyordu -- vazgeçen kullanıcı kaydı
// iptal etmiş oluyordu. Burada Vazgeç/ESC her zaman null'dur:
//   const { askReason, dialog } = useReasonDialog();
//   const reason = await askReason({ title: "Tahsilatı İptal Et", danger: true });
//   if (reason === null) return;
//   return <>...{dialog}</>;
export function useReasonDialog() {
  const [state, setState] = useState<{
    options: ReasonOptions;
    resolve: (value: string | null) => void;
  } | null>(null);

  function askReason(options: ReasonOptions): Promise<string | null> {
    return new Promise((resolve) => {
      setState({ options, resolve });
    });
  }

  function finish(value: string | null) {
    state?.resolve(value);
    setState(null);
  }

  const dialog = state ? <ReasonModal options={state.options} onDone={finish} /> : null;
  return { askReason, dialog };
}

function ReasonModal({ options, onDone }: { options: ReasonOptions; onDone: (value: string | null) => void }) {
  const [reason, setReason] = useState("");
  const trimmed = reason.trim();
  const blocked = Boolean(options.required) && trimmed === "";

  function submit(e: FormEvent) {
    e.preventDefault();
    if (!blocked) onDone(trimmed);
  }

  return (
    <Modal
      open
      onClose={() => onDone(null)}
      title={options.title}
      footer={
        <>
          <Button type="button" variant="ghost" onClick={() => onDone(null)}>
            {options.cancelLabel ?? "Vazgeç"}
          </Button>
          <Button type="submit" form="reason-dialog-form" variant={options.danger ? "danger" : "primary"} disabled={blocked}>
            {options.confirmLabel ?? "Onayla"}
          </Button>
        </>
      }
    >
      <form id="reason-dialog-form" onSubmit={submit} className="flex flex-col gap-3">
        {options.message && <p className="text-text">{options.message}</p>}
        <Textarea
          name="reason"
          label={`${options.label ?? "Gerekçe"} (${options.required ? "zorunlu" : "opsiyonel"})`}
          placeholder={options.placeholder}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          className="min-h-20"
          autoFocus
        />
      </form>
    </Modal>
  );
}
