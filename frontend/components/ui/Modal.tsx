"use client";

import { X } from "lucide-react";
import { useEffect, useRef } from "react";

// native <dialog> + showModal() üzerine kurulu -- focus-trap, backdrop,
// ESC ve top-layer davranışı TARAYICIDAN bedava gelir, ekstra bir
// dependency veya elle yazılmış focus-trap mantığı gerekmez.
export function Modal({
  open,
  onClose,
  title,
  children,
  footer,
  widthClassName = "max-w-md",
  dismissible = true,
}: {
  open: boolean;
  onClose: () => void;
  title?: string;
  children: React.ReactNode;
  footer?: React.ReactNode;
  // Mevcut tüm kullanım yerleri bunu vermediği için max-w-md korunur;
  // Metraj Hesapla gibi tablo içeren geniş paneller için override edilir.
  widthClassName?: string;
  // false iken (ör. kayıt isteği sürerken) kullanıcı ESC, kapat düğmesi
  // veya arka plan tıklamasıyla kapatamaz. Tarayıcı ESC'yi yine de zorla
  // uygularsa (tekrarlanan ESC'de Chrome cancel'ın engellenmesini yok
  // sayar) native "close" olayı onClose'u çağırır -- çağıranın open
  // durumu dialog'la uyumlu kalsın diye onClose'u koşulsuz uygulaması
  // gerekir.
  dismissible?: boolean;
}) {
  const ref = useRef<HTMLDialogElement>(null);

  useEffect(() => {
    const dialog = ref.current;
    if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
  }, [open]);

  function handleBackdropClick(e: React.MouseEvent<HTMLDialogElement>) {
    // ::backdrop gerçek bir DOM düğümü değildir -- tıklaması dialog
    // elemanının KENDİ kutusuna (içerik div'lerinin dışına) düşer, bu
    // yüzden target === dialog kontrolü "arka plana tıklandı" demektir.
    if (dismissible && e.target === ref.current) onClose();
  }

  function handleCancel(e: React.SyntheticEvent<HTMLDialogElement>) {
    // ESC: kapatılamaz durumdayken tarayıcının dialog'u kapatmasını engelle.
    if (!dismissible) {
      e.preventDefault();
      return;
    }
    onClose();
  }

  return (
    <dialog
      ref={ref}
      onClose={onClose}
      onCancel={handleCancel}
      onClick={handleBackdropClick}
      className={`m-auto w-full ${widthClassName} rounded-lg border border-border bg-surface p-0 text-text shadow-xl backdrop:bg-black/40`}
    >
      <div className="flex items-center justify-between border-b border-border px-5 py-4">
        {title && <h2 className="text-sm font-semibold">{title}</h2>}
        <button
          type="button"
          onClick={onClose}
          disabled={!dismissible}
          aria-label="Kapat"
          className="ml-auto text-text-muted hover:text-text disabled:cursor-not-allowed disabled:opacity-40"
        >
          <X size={18} strokeWidth={1.75} />
        </button>
      </div>
      <div className="max-h-[75vh] overflow-y-auto px-5 py-4 text-sm">{children}</div>
      {footer && <div className="flex justify-end gap-2 border-t border-border px-5 py-4">{footer}</div>}
    </dialog>
  );
}
