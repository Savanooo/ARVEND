import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  accessTokenState,
  cookieValueFrom,
  createRefreshCoordinator,
  replaceCookies,
  requestRefresh,
  type RefreshResult,
} from "./session-refresh.ts";

// Çalıştırma: npm test  (node --test "lib/**/*.test.mts") -- Next'siz.

function jwt(payload: Record<string, unknown>): string {
  const enc = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  return `${enc({ alg: "HS256", typ: "JWT" })}.${enc(payload)}.imza`;
}

const NOW = 1_800_000_000_000;

describe("accessTokenState", () => {
  it("çerez yoksa missing", () => {
    assert.equal(accessTokenState(undefined, NOW), "missing");
    assert.equal(accessTokenState("", NOW), "missing");
  });

  it("geçerli token fresh -- her istekte yenileme YOK", () => {
    assert.equal(accessTokenState(jwt({ exp: NOW / 1000 + 600 }), NOW), "fresh");
  });

  it("leeway içinde dolacak token expiring, dolmuş token expired", () => {
    assert.equal(accessTokenState(jwt({ exp: NOW / 1000 + 10 }), NOW), "expiring");
    assert.equal(accessTokenState(jwt({ exp: NOW / 1000 }), NOW), "expired");
    assert.equal(accessTokenState(jwt({ exp: NOW / 1000 - 60 }), NOW), "expired");
  });

  it("okunamayan token kullanılamaz; exp'siz token'a dokunulmaz (sonsuz yenileme yok)", () => {
    assert.equal(accessTokenState("bozuk", NOW), "expired");
    assert.equal(accessTokenState(jwt({ role: "admin" }), NOW), "fresh");
  });
});

describe("çerez yardımcıları", () => {
  const setCookies = [
    "access_token=AAA.BBB.CCC; Path=/; Max-Age=900; HttpOnly; SameSite=Strict",
    "refresh_token=r2; Path=/; Max-Age=2592000; HttpOnly; SameSite=Strict",
  ];

  it("Set-Cookie satırından değer okunur", () => {
    assert.equal(cookieValueFrom(setCookies, "access_token"), "AAA.BBB.CCC");
    assert.equal(cookieValueFrom(setCookies, "refresh_token"), "r2");
    assert.equal(cookieValueFrom(setCookies, "yok"), null);
  });

  it("istek Cookie başlığında eski çift yenisiyle değişir, diğer çerezler korunur", () => {
    assert.equal(
      replaceCookies("theme=dark; refresh_token=r1; sidebar=1", { access_token: "a2", refresh_token: "r2" }),
      "theme=dark; sidebar=1; access_token=a2; refresh_token=r2"
    );
    assert.equal(replaceCookies(null, { access_token: "a2" }), "access_token=a2");
  });
});

describe("requestRefresh", () => {
  it("refresh token'ı Cookie başlığıyla gönderir, yeni çifti ve ham Set-Cookie'leri döner", async () => {
    let seen: { url: string; init?: RequestInit } | null = null;
    const headers = new Headers();
    headers.append("Set-Cookie", "access_token=a2; Path=/; Max-Age=900; HttpOnly");
    headers.append("Set-Cookie", "refresh_token=r2; Path=/; Max-Age=2592000; HttpOnly");
    const result = await requestRefresh("http://api.local", "r1", async (url, init) => {
      seen = { url, init };
      return new Response("{}", { status: 200, headers });
    });
    assert.ok(result.ok);
    assert.equal(result.accessToken, "a2");
    assert.equal(result.refreshToken, "r2");
    assert.equal(result.setCookies.length, 2);
    assert.equal(seen!.url, "http://api.local/api/v1/auth/refresh");
    assert.equal(seen!.init?.method, "POST");
    assert.deepEqual(seen!.init?.headers, { Cookie: "refresh_token=r1" });
  });

  it("401'de backend'in temizleyen çerezlerini çağırana bırakır", async () => {
    const headers = new Headers();
    headers.append("Set-Cookie", "access_token=; Path=/; Max-Age=0");
    const result = await requestRefresh("http://api.local", "r1", async () => new Response("{}", { status: 401, headers }));
    assert.deepEqual(result, { ok: false, status: 401, setCookies: ["access_token=; Path=/; Max-Age=0"] });
  });

  it("ağ hatası throw etmez", async () => {
    const result = await requestRefresh("http://api.local", "r1", async () => {
      throw new TypeError("fetch failed");
    });
    assert.deepEqual(result, { ok: false, status: null, setCookies: [] });
  });
});

describe("createRefreshCoordinator (tek kullanımlık refresh token)", () => {
  const ok = (n: number): RefreshResult => ({
    ok: true,
    accessToken: `a${n}`,
    refreshToken: `r${n}`,
    setCookies: [`access_token=a${n}`, `refresh_token=r${n}`],
  });

  it("aynı token'la eşzamanlı istekler TEK refresh çağrısını paylaşır", async () => {
    let calls = 0;
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const refreshOnce = createRefreshCoordinator({
      refresh: async () => {
        calls++;
        await gate;
        return ok(2);
      },
    });
    const pending = [refreshOnce("r1"), refreshOnce("r1"), refreshOnce("r1")];
    release();
    const results = await Promise.all(pending);
    assert.equal(calls, 1);
    for (const r of results) assert.deepEqual(r, ok(2));
  });

  it("başarılı sonuç grace süresince eski token'la gelenlere de verilir, sonra unutulur", async () => {
    let t = NOW;
    let calls = 0;
    const refreshOnce = createRefreshCoordinator({
      graceMs: 20_000,
      now: () => t,
      refresh: async () => ok(++calls + 1),
    });
    assert.deepEqual(await refreshOnce("r1"), ok(2));
    t += 5_000;
    assert.deepEqual(await refreshOnce("r1"), ok(2), "geç kalan istek aynı yeni çifti alır");
    assert.equal(calls, 1);
    t += 30_000;
    await refreshOnce("r1");
    assert.equal(calls, 2, "grace bitince bellekte tutulmaz");
  });

  it("başarısız sonuç saklanmaz: sonraki istek yeniden dener", async () => {
    let calls = 0;
    const refreshOnce = createRefreshCoordinator({
      refresh: async () => {
        calls++;
        return calls === 1 ? { ok: false, status: null, setCookies: [] } : ok(2);
      },
    });
    assert.equal((await refreshOnce("r1")).ok, false);
    assert.equal((await refreshOnce("r1")).ok, true);
    assert.equal(calls, 2);
  });
});
