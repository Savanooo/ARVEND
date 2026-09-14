import assert from "node:assert/strict";
import { afterEach, beforeEach, describe, it, mock } from "node:test";

import { apiClient, ApiError, fetchWithSession } from "./api.ts";

// Node 24 TypeScript'i doğrudan çalıştırır (type stripping); ek bağımlılık yok.
// Çalıştırma: npm test  (node --test "lib/**/*.test.ts")

const REFRESH = "/api/v1/auth/refresh";

type FetchCall = { path: string; init: RequestInit | undefined };

/**
 * Yol bazlı sahte fetch. Her yol için sırayla tüketilen yanıt üreticileri;
 * Response gövdesi tek kullanımlık olduğundan her çağrıda yenisi üretilir.
 */
function scriptedFetch(script: Record<string, Array<() => Promise<Response> | Response>>) {
  const calls: FetchCall[] = [];
  const impl = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const path = new URL(url).pathname;
    calls.push({ path, init });
    const queue = script[path];
    if (!queue || queue.length === 0) {
      throw new Error(`beklenmeyen fetch: ${path} (${calls.length}. çağrı)`);
    }
    return queue.shift()!();
  };
  return { calls, impl };
}

const json = (status: number, body: unknown) => () =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

const unauthorized = json(401, { error: "oturum geçersiz veya süresi dolmuş" });

function deferred<T>() {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

describe("apiClient oturum yenileme", () => {
  let assign: ReturnType<typeof mock.fn>;

  beforeEach(() => {
    assign = mock.fn();
    // jsdom yok: redirectToLogin'in dokunduğu kadarını taklit et.
    (globalThis as { window?: unknown }).window = {
      location: { pathname: "/teklifler", assign },
    };
  });

  afterEach(() => {
    delete (globalThis as { window?: unknown }).window;
    mock.restoreAll();
  });

  it("access token süresi dolunca: 401 -> tek refresh -> orijinal istek bir kez tekrarlanır", async (t) => {
    const { calls, impl } = scriptedFetch({
      "/api/v1/offers": [unauthorized, json(200, { offers: [{ id: "1" }] })],
      [REFRESH]: [json(200, { id: "u1" })],
    });
    t.mock.method(globalThis, "fetch", impl);

    const result = await apiClient<{ offers: { id: string }[] }>("/api/v1/offers");

    assert.deepEqual(result, { offers: [{ id: "1" }] });
    assert.deepEqual(
      calls.map((c) => c.path),
      ["/api/v1/offers", REFRESH, "/api/v1/offers"]
    );
    const refreshCall = calls[1];
    assert.equal(refreshCall.init?.method, "POST");
    assert.equal(refreshCall.init?.credentials, "include", "refresh HttpOnly cookie ile gitmeli");
    assert.equal(refreshCall.init?.body, undefined, "refresh token JS'ten gönderilmez, cookie'de kalır");
    assert.equal(calls[2].init?.credentials, "include");
    assert.equal(assign.mock.callCount(), 0);
  });

  it("paralel 401'ler tek bir refresh isteğini paylaşır (single-flight)", async (t) => {
    const gate = deferred<Response>();
    const PARALLEL = 6;
    const script: Record<string, Array<() => Promise<Response> | Response>> = {
      [REFRESH]: [() => gate.promise],
    };
    for (let i = 0; i < PARALLEL; i++) {
      script[`/api/v1/projects/${i}`] = [unauthorized, json(200, { id: String(i) })];
    }
    const { calls, impl } = scriptedFetch(script);
    t.mock.method(globalThis, "fetch", impl);

    const pending = Array.from({ length: PARALLEL }, (_, i) =>
      apiClient<{ id: string }>(`/api/v1/projects/${i}`)
    );

    // Tüm 401'ler gelsin ve hepsi refresh'e yanaşsın; refresh hâlâ askıda.
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(
      calls.filter((c) => c.path === REFRESH).length,
      1,
      "askıdaki refresh varken ikinci bir refresh isteği çıkmamalı"
    );
    assert.equal(calls.length, PARALLEL + 1, "refresh bitmeden hiçbir retry gönderilmemeli");

    gate.resolve(json(200, { id: "u1" })());
    const results = await Promise.all(pending);

    assert.deepEqual(
      results.map((r) => r.id),
      Array.from({ length: PARALLEL }, (_, i) => String(i))
    );
    assert.equal(calls.filter((c) => c.path === REFRESH).length, 1);
    assert.equal(calls.length, PARALLEL * 2 + 1, "her istek tam bir kez tekrarlanır");
    assert.equal(assign.mock.callCount(), 0);
  });

  it("refresh 401 dönerse /giris'e yönlendirir, retry yapmaz", async (t) => {
    const { calls, impl } = scriptedFetch({
      "/api/v1/offers": [unauthorized],
      [REFRESH]: [json(401, { error: "refresh token yok" })],
    });
    t.mock.method(globalThis, "fetch", impl);

    await assert.rejects(apiClient("/api/v1/offers"), (err: unknown) => {
      assert.ok(err instanceof ApiError);
      assert.equal(err.status, 401);
      return true;
    });
    assert.deepEqual(
      calls.map((c) => c.path),
      ["/api/v1/offers", REFRESH]
    );
    assert.equal(assign.mock.callCount(), 1);
    assert.deepEqual(assign.mock.calls[0].arguments, ["/giris"]);
  });

  it("refresh 403 (pasif kullanıcı) da /giris akışına gider", async (t) => {
    const { impl } = scriptedFetch({
      "/api/v1/offers": [unauthorized],
      [REFRESH]: [json(403, { error: "kullanıcı pasif durumda" })],
    });
    t.mock.method(globalThis, "fetch", impl);

    await assert.rejects(apiClient("/api/v1/offers"), ApiError);
    assert.equal(assign.mock.callCount(), 1);
  });

  it("retry de 401 dönerse ikinci bir refresh başlatılmaz (sonsuz döngü yok)", async (t) => {
    const { calls, impl } = scriptedFetch({
      "/api/v1/offers": [unauthorized, unauthorized],
      [REFRESH]: [json(200, { id: "u1" })],
    });
    t.mock.method(globalThis, "fetch", impl);

    await assert.rejects(apiClient("/api/v1/offers"), ApiError);
    assert.deepEqual(
      calls.map((c) => c.path),
      ["/api/v1/offers", REFRESH, "/api/v1/offers"]
    );
    assert.equal(assign.mock.callCount(), 1);
  });

  it("refresh ağ hatası/5xx verirse yönlendirmez, orijinal 401 hatası döner", async (t) => {
    const { calls, impl } = scriptedFetch({
      "/api/v1/offers": [unauthorized],
      [REFRESH]: [() => Promise.reject(new TypeError("fetch failed"))],
    });
    t.mock.method(globalThis, "fetch", impl);

    await assert.rejects(apiClient("/api/v1/offers"), (err: unknown) => {
      assert.ok(err instanceof ApiError);
      assert.equal(err.status, 401);
      return true;
    });
    assert.equal(calls.length, 2, "retry yok");
    assert.equal(assign.mock.callCount(), 0, "geçici kesintide oturum düşürülmez");
  });

  it("login 401'i refresh tetiklemez; hata mesajı forma döner", async (t) => {
    const { calls, impl } = scriptedFetch({
      "/api/v1/auth/login": [json(401, { error: "kullanıcı adı veya şifre hatalı" })],
    });
    t.mock.method(globalThis, "fetch", impl);

    await assert.rejects(
      apiClient("/api/v1/auth/login", { method: "POST", body: "{}" }),
      (err: unknown) => {
        assert.ok(err instanceof ApiError);
        assert.equal(err.message, "kullanıcı adı veya şifre hatalı");
        return true;
      }
    );
    assert.equal(calls.length, 1);
    assert.equal(assign.mock.callCount(), 0);
  });

  it("refresh ucunun kendisi retry döngüsüne girmez", async (t) => {
    const { calls, impl } = scriptedFetch({
      [REFRESH]: [json(401, { error: "refresh token yok" })],
    });
    t.mock.method(globalThis, "fetch", impl);

    await assert.rejects(apiClient(REFRESH, { method: "POST" }), ApiError);
    assert.equal(calls.length, 1);
    assert.equal(assign.mock.callCount(), 0);
  });

  it("refresh tamamlandıktan sonra gelen yeni 401 yeni bir refresh başlatır", async (t) => {
    const { calls, impl } = scriptedFetch({
      "/api/v1/offers": [unauthorized, json(200, { n: 1 }), unauthorized, json(200, { n: 2 })],
      [REFRESH]: [json(200, { id: "u1" }), json(200, { id: "u1" })],
    });
    t.mock.method(globalThis, "fetch", impl);

    assert.deepEqual(await apiClient("/api/v1/offers"), { n: 1 });
    assert.deepEqual(await apiClient("/api/v1/offers"), { n: 2 });
    assert.equal(calls.filter((c) => c.path === REFRESH).length, 2, "single-flight durumu sıfırlanmalı");
  });

  it("zaten /giris'teyken yönlendirme tekrarlanmaz", async (t) => {
    (globalThis as { window?: unknown }).window = {
      location: { pathname: "/giris", assign },
    };
    const { impl } = scriptedFetch({
      "/api/v1/offers": [unauthorized],
      [REFRESH]: [json(401, { error: "refresh token yok" })],
    });
    t.mock.method(globalThis, "fetch", impl);

    await assert.rejects(apiClient("/api/v1/offers"), ApiError);
    assert.equal(assign.mock.callCount(), 0);
  });

  it("fetchWithSession multipart gövdeyi tekrar gönderebilir (upload yolu)", async (t) => {
    const { calls, impl } = scriptedFetch({
      "/api/v1/projects/p1/files": [unauthorized, json(201, { id: "f1" })],
      [REFRESH]: [json(200, { id: "u1" })],
    });
    t.mock.method(globalThis, "fetch", impl);

    const form = new FormData();
    form.append("file", new Blob(["x"]), "a.txt");
    const res = await fetchWithSession("/api/v1/projects/p1/files", { method: "POST", body: form });

    assert.equal(res.status, 201);
    assert.equal(calls.length, 3);
    assert.equal(calls[2].init?.body, form, "aynı FormData ile tekrar gönderilir");
    assert.equal(calls[2].init?.credentials, "include");
  });
});
