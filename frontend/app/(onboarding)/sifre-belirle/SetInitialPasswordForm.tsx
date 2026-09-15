"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Logo } from "@/components/layout/Logo";
import { apiClient, ApiError } from "@/lib/api";

// "İlk giriş" akışı: Super Admin'in provision ettiği bir Owner, geçici
// şifreyle giriş yaptıktan sonra buraya yönlendirilir (bkz. (onboarding)/
// layout.tsx + tüm diğer layout'lardaki enforceFirstLoginFlow). Mevcut
// şifreyi İSTEMEZ -- kullanıcı zaten oturum açmış durumda (profildeki
// "Şifre Değiştir" akışından farkı budur).
export function SetInitialPasswordForm() {
  const router = useRouter();
  const [newPassword, setNewPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    if (newPassword.length < 8) {
      setError("Şifre en az 8 karakter olmalı");
      return;
    }
    if (newPassword !== confirmPassword) {
      setError("Şifreler eşleşmiyor");
      return;
    }
    setLoading(true);
    try {
      await apiClient("/api/v1/users/me/set-initial-password", {
        method: "POST",
        body: JSON.stringify({ new_password: newPassword }),
      });
      // Sunucudaki must_change_password bayrağı temizlendi -- router.refresh()
      // ile layout'un getCurrentUser()'ı tazelenir, enforceFirstLoginFlow
      // bir sonraki adıma (onboarding tamamlanmadıysa /kurulum, aksi halde
      // ana sayfa) yönlendirir. redirect() burada YAPILMAZ -- doğru hedefi
      // sunucu (layout) belirler.
      router.push("/");
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setLoading(false);
    }
  }

  return (
    <Card className="mx-auto w-full max-w-sm">
      <CardBody className="flex flex-col gap-6">
        <div className="flex flex-col items-center gap-3 text-center">
          <Logo size={52} />
          <div>
            <h1 className="text-sm font-bold uppercase tracking-widest">Yeni Şifre Belirleyin</h1>
            <p className="text-xs text-text-muted">
              İlk girişte, size verilen geçici şifre yerine kendi şifrenizi belirlemeniz gerekiyor.
            </p>
          </div>
        </div>

        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <Input
            label="Yeni Şifre"
            type="password"
            autoComplete="new-password"
            minLength={8}
            required
            value={newPassword}
            onChange={(e) => setNewPassword(e.target.value)}
          />
          <Input
            label="Yeni Şifre (Tekrar)"
            type="password"
            autoComplete="new-password"
            required
            value={confirmPassword}
            onChange={(e) => setConfirmPassword(e.target.value)}
          />
          {error && <p className="text-xs text-danger">{error}</p>}
          <Button type="submit" disabled={loading} className="mt-2 w-full">
            {loading ? "Kaydediliyor…" : "Devam Et"}
          </Button>
        </form>
      </CardBody>
    </Card>
  );
}
