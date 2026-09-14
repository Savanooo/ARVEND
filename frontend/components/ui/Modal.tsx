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
}: {
  open: boolean;
  onClose: () => void;
  title?: string;
  children: React.ReactNode;
  footer?: React.ReactNode;
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
    if (e.target === ref.current) onClose();
  }

  return (
    <dialog
      ref={ref}
      onClose={onClose}
      onCancel={onClose}
      onClick={handleBackdropClick}
      className="w-full max-w-md rounded-lg border border-border bg-surface p-0 text-text shadow-lg backdrop:bg-black/40"
    >
      <div className="flex items-center justify-between border-b border-border px-5 py-4">
        {title && <h2 className="text-sm font-semibold">{title}</h2>}
        <button
          type="button"
          onClick={onClose}
          aria-label="Kapat"
          className="ml-auto text-text-muted hover:text-text"
        >
          <X size={18} strokeWidth={1.75} />
        </button>
      </div>
      <div className="px-5 py-4 text-sm">{children}</div>
      {footer && <div className="flex justify-end gap-2 border-t border-border px-5 py-4">{footer}</div>}
    </dialog>
  );
}
