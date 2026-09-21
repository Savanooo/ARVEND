"use client";

import { X } from "lucide-react";
import { useEffect, useRef } from "react";

// Modal.tsx'in native <dialog> + showModal() temeliyle AYNI (focus trap,
// ESC ile kapama, kapanışta odağı geri verme tarayıcıdan bedava gelir,
// bkz. Modal.tsx yorumu) -- yalnızca yerleşimi farklıdır: ortalanmış küçük
// bir kutu yerine viewport'un SAĞINDAN açılan tam yükseklikte bir panel.
// Süper Admin'in "Kullanıcı Oluştur" gibi çok alanlı formları için (bkz.
// Modal.tsx: onay/küçük formlar merkezi kalır) -- iki ayrı bileşen, TEK
// tutarlı etkileşim modeli (aynı overlay/backdrop, aynı kapanış/focus
// davranışı, aynı Card/typography dili).
export function Drawer({
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
    if (e.target === ref.current) onClose();
  }

  return (
    <dialog
      ref={ref}
      onClose={onClose}
      onCancel={onClose}
      onClick={handleBackdropClick}
      // Tarayıcının dialog top-layer varsayılanı left/right/top/bottom
      // hepsini 0'lar (bkz. Modal.tsx'teki merkezleme yorumunun AKSİ ucu):
      // left'i AÇIKÇA auto'ya çekmezsek, genişlik + left:0 + right:0 aşırı-
      // kısıtlanmış CSS kuralı gereği panel SOLA yapışır, sağa değil.
      className="fixed inset-y-0 left-auto right-0 m-0 h-screen max-h-screen w-full max-w-[480px] rounded-none border-0 border-l border-border bg-surface p-0 text-text shadow-xl backdrop:bg-black/40"
    >
      <div className="flex h-full flex-col">
        <div className="flex shrink-0 items-center justify-between border-b border-border px-6 py-4">
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
        <div className="flex-1 overflow-y-auto px-6 py-5 text-sm">{children}</div>
        {footer && <div className="flex shrink-0 justify-end gap-2 border-t border-border px-6 py-4">{footer}</div>}
      </div>
    </dialog>
  );
}
