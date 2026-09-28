"use client";

import { Loader2 } from "lucide-react";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";

import { Modal } from "@/components/ui/Modal";
import { SearchInput } from "@/components/ui/SearchInput";
import { FOCUS_RING, buttonClass } from "@/components/ui/styles";
import { apiClient } from "@/lib/api";
import { COPY, PROJECT_OPTIONS_PATH, projectHref, type ProjectOption, type ProjectTab } from "@/lib/dashboard";

// Proje gerektiren hızlı işlemler (Tahsilat/Masraf Gir, Satın Alma Talebi,
// Görev Ekle) önce projeyi sordurur, sonra proje sayfasının ilgili
// sekmesini açar. Liste GET /projects'ten DEĞİL, tutar alanı taşımayan
// üyelik kapsamlı /dashboard/project-options'tan gelir. Tek açık proje
// varsa seçici atlanır.

type ProjectOptionsResponse = { projects: ProjectOption[] };

function optionsPath(q: string): string {
  const term = q.trim();
  return term ? `${PROJECT_OPTIONS_PATH}?q=${encodeURIComponent(term)}` : PROJECT_OPTIONS_PATH;
}

interface PickerState {
  tab: ProjectTab;
  initial: ProjectOption[] | null;
}

export function useProjectPicker() {
  const router = useRouter();
  const [state, setState] = useState<PickerState | null>(null);
  const [busy, setBusy] = useState(false);
  // Seçici kapanınca odağın döneceği öğe (tetik düğmesi ya da menü tetiği).
  // Seçici durumdan kaldırılınca <dialog> kapanmadan DOM'dan çıkar; tarayıcı
  // odağı geri vermez, bu yüzden elle geri verilir.
  const returnFocus = useRef<HTMLElement | null>(null);
  const wasOpen = useRef(false);

  useEffect(() => {
    if (state) {
      wasOpen.current = true;
      return;
    }
    if (!wasOpen.current) return;
    wasOpen.current = false;
    const el = returnFocus.current;
    returnFocus.current = null;
    if (el?.isConnected) el.focus();
  }, [state]);

  async function start(tab: ProjectTab, returnTo?: HTMLElement | null) {
    if (busy) return;
    returnFocus.current = returnTo ?? null;
    setBusy(true);
    try {
      const res = await apiClient<ProjectOptionsResponse>(PROJECT_OPTIONS_PATH);
      if (res.projects.length === 1) {
        router.push(projectHref(res.projects[0].id, tab));
        return;
      }
      setState({ tab, initial: res.projects });
    } catch {
      // Hata seçicinin içinde gösterilir (arama ile tekrar denenebilir).
      setState({ tab, initial: null });
    } finally {
      setBusy(false);
    }
  }

  const modal = state ? (
    <ProjectPickerModal
      initial={state.initial}
      onClose={() => setState(null)}
      onPick={(p) => {
        const tab = state.tab;
        setState(null);
        router.push(projectHref(p.id, tab));
      }}
    />
  ) : null;

  return { start, busy, modal };
}

function ProjectPickerModal({
  initial,
  onPick,
  onClose,
}: {
  initial: ProjectOption[] | null;
  onPick: (p: ProjectOption) => void;
  onClose: () => void;
}) {
  const [q, setQ] = useState("");
  const [projects, setProjects] = useState<ProjectOption[] | null>(initial);
  const [failed, setFailed] = useState(initial === null);
  const [loading, setLoading] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const seq = useRef(0);

  useEffect(
    () => () => {
      if (timer.current) clearTimeout(timer.current);
    },
    []
  );

  async function load(term: string) {
    const id = ++seq.current;
    setLoading(true);
    try {
      const res = await apiClient<ProjectOptionsResponse>(optionsPath(term));
      if (id !== seq.current) return;
      setProjects(res.projects);
      setFailed(false);
    } catch {
      if (id !== seq.current) return;
      setProjects(null);
      setFailed(true);
    } finally {
      if (id === seq.current) setLoading(false);
    }
  }

  function onSearch(value: string) {
    setQ(value);
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => void load(value), 250);
  }

  return (
    <Modal open onClose={onClose} title={COPY.pickerTitle}>
      <div className="flex flex-col gap-3">
        <SearchInput
          value={q}
          onChange={(e) => onSearch(e.target.value)}
          placeholder={COPY.pickerSearch}
          aria-label={COPY.pickerSearch}
          autoFocus
        />
        <div className="min-h-10">
          {/* Canlı bölge YALNIZCA kısa durum satırıdır; liste dışarıda kalır
              (her aramada 50 proje adı okunmasın). */}
          <div aria-live="polite">
            {loading && (
              <p className="flex items-center gap-2 text-xs text-text-muted">
                <Loader2 size={14} strokeWidth={2} className="animate-spin motion-reduce:animate-none" aria-hidden />
                {COPY.pickerLoading}
              </p>
            )}
            {!loading && failed && <p className="text-sm text-danger">{COPY.pickerError}</p>}
            {!loading && !failed && projects && projects.length === 0 && (
              <p className="text-sm text-text-muted">{COPY.pickerEmpty}</p>
            )}
            {!loading && !failed && projects && projects.length > 0 && (
              <p className="sr-only">{COPY.pickerCount(projects.length)}</p>
            )}
          </div>
          {!loading && failed && (
            <div className="mt-2">
              <button type="button" onClick={() => void load(q)} className={buttonClass("secondary", "sm")}>
                {COPY.retry}
              </button>
            </div>
          )}
          {!loading && !failed && projects && projects.length > 0 && (
            <ul className="-mx-2 flex flex-col">
              {projects.map((p) => (
                <li key={p.id}>
                  <button
                    type="button"
                    onClick={() => onPick(p)}
                    className={`flex min-h-11 w-full flex-col items-start rounded-md px-2 py-2 text-left hover:bg-gold-soft/30 ${FOCUS_RING}`}
                  >
                    <span className="text-sm font-medium text-text">{p.name}</span>
                    <span className="text-xs text-text-muted">
                      {p.project_no}
                      {p.customer_name ? ` · ${p.customer_name}` : ""}
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </Modal>
  );
}
