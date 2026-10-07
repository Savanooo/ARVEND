"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody } from "@/components/ui/Card";
import { Input } from "@/components/ui/Input";
import { Logo } from "@/components/layout/Logo";
import { apiClient, ApiError } from "@/lib/api";
import { loginDestination } from "@/lib/route-policy";
import type { User } from "@/lib/types";

// next: doğrulanmış (safeNextPath) dönüş yolu -- oturumu düşen kullanıcı
// giriş yapınca kaldığı sayfaya döner.
export function LoginForm({ next }: { next: string | null }) {
  const router = useRouter();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const user = await apiClient<User>("/api/v1/auth/login", {
        method: "POST",
        body: JSON.stringify({ username, password }),
      });
      router.push(loginDestination(user, next));
      router.refresh();
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "Bağlantı hatası");
    } finally {
      setLoading(false);
    }
  }

  return (
    <Card className="w-full max-w-sm">
      <CardBody className="flex flex-col gap-6">
        <div className="flex flex-col items-center gap-3 text-center">
          <Logo size={52} />
          <div>
            <h1 className="text-sm font-bold uppercase tracking-widest">
              Arvend Yapı
            </h1>
            <p className="text-xs text-text-muted">Yönetim Sistemine Giriş</p>
          </div>
        </div>

        <form onSubmit={handleSubmit} className="flex flex-col gap-4">
          <Input
            label="Kullanıcı Adı"
            name="username"
            autoComplete="username"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            required
          />
          <Input
            label="Şifre"
            name="password"
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
          />
          {error && <p className="text-xs text-danger">{error}</p>}
          <Button type="submit" disabled={loading} className="mt-2 w-full">
            {loading ? "Giriş yapılıyor…" : "Giriş Yap"}
          </Button>
        </form>
      </CardBody>
    </Card>
  );
}
