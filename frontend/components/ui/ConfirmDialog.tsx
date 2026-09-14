"use client";

import { useState } from "react";

import { Button } from "./Button";
import { Modal } from "./Modal";

interface ConfirmOptions {
  title?: string;
  message: string;
  confirmLabel?: string;
  cancelLabel?: string;
  danger?: boolean;
}

// window.confirm()'ün yerini alır -- çağrı yeri aynı kalır (tek bir
// async çağrı + boolean sonuç), yalnızca senkron değil async olur:
//   const { confirm, dialog } = useConfirmDialog();
//   ...
//   if (!(await confirm({ message: "Emin misiniz?" }))) return;
//   ...
//   return <>...{dialog}</>;
export function useConfirmDialog() {
  const [state, setState] = useState<{
    options: ConfirmOptions;
    resolve: (value: boolean) => void;
  } | null>(null);

  function confirm(options: ConfirmOptions): Promise<boolean> {
    return new Promise((resolve) => {
      setState({ options, resolve });
    });
  }

  function handle(result: boolean) {
    state?.resolve(result);
    setState(null);
  }

  const dialog = state ? (
    <Modal
      open
      onClose={() => handle(false)}
      title={state.options.title ?? "Onay"}
      footer={
        <>
          <Button variant="ghost" onClick={() => handle(false)}>
            {state.options.cancelLabel ?? "Vazgeç"}
          </Button>
          <Button variant={state.options.danger ? "danger" : "primary"} onClick={() => handle(true)}>
            {state.options.confirmLabel ?? "Onayla"}
          </Button>
        </>
      }
    >
      <p className="text-text">{state.options.message}</p>
    </Modal>
  ) : null;

  return { confirm, dialog };
}
