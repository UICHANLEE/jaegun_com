import { BIBLE_BOOKS, chapterID } from "./bibleCanon";
export interface BibleVerse { verse: number; text: string }
export interface BibleChapter { id: number; book: number; chapter: number; reference: string; verses: BibleVerse[] }
export interface BibleManifest { id: string; title: string; attribution: string; license: string; source: string; archive_sha256: string; chapters: { id: number; verses: number; sha256: string }[] }
export const BIBLE_CACHE = "jaegun-korrv-2.0.1";
export function parseBibleChapter(value: unknown, expectedId: number): BibleChapter {
  const row = value as BibleChapter;
  if (!row || row.id !== expectedId || !Number.isInteger(row.book) || !BIBLE_BOOKS[row.book] || chapterID(row.book, row.chapter) !== expectedId || row.reference !== `${BIBLE_BOOKS[row.book][0]} ${row.chapter}장` || !Array.isArray(row.verses) || !row.verses.length || row.verses.some((v, i) => v.verse !== i + 1 || typeof v.text !== "string")) throw new Error("성경 장 데이터를 확인하지 못했습니다.");
  return row;
}
export async function loadBibleManifest(signal?: AbortSignal): Promise<BibleManifest> {
  const response = await fetch("/bible/krv/manifest.json", { signal });
  if (!response.ok) throw new Error("성경 출처 정보를 불러오지 못했습니다.");
  const row = await response.json() as BibleManifest;
  if (row.id !== "korrv-2.0.1" || row.chapters?.length !== 1189 || row.chapters.some((c, i) => c.id !== i + 1 || !Number.isInteger(c.verses) || c.verses < 1 || !/^[0-9a-f]{64}$/.test(c.sha256))) throw new Error("성경 자료 목록이 올바르지 않습니다.");
  return row;
}
export async function loadBibleChapter(id: number, manifest: BibleManifest, signal?: AbortSignal): Promise<BibleChapter> {
  const response = await fetch(`/bible/krv/${id}.json`, { signal });
  if (!response.ok) throw new Error("본문을 불러오지 못했습니다. 연결 또는 오프라인 저장 상태를 확인해 주세요.");
  return decodeBibleResponse(response, id, manifest);
}
async function decodeBibleResponse(response: Response, id: number, manifest: BibleManifest): Promise<BibleChapter> {
  const bytes = await response.arrayBuffer();
  const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), (v) => v.toString(16).padStart(2, "0")).join("");
  if (hash !== manifest.chapters[id - 1]?.sha256) throw new Error("본문 무결성 확인에 실패했습니다.");
  const chapter = parseBibleChapter(JSON.parse(new TextDecoder().decode(bytes)), id);
  if (chapter.verses.length !== manifest.chapters[id - 1].verses) throw new Error("본문 절 수가 다릅니다.");
  return chapter;
}
export async function packageBibleOffline(manifest: BibleManifest, onProgress: (count: number) => void, signal: AbortSignal) {
  if (!("serviceWorker" in navigator) || !("caches" in window)) throw new Error("이 브라우저는 오프라인 저장을 지원하지 않습니다.");
  const registration = await navigator.serviceWorker.register("/faith-offline-sw.js", { scope: "/bible" });
  const worker = registration.installing ?? registration.waiting ?? registration.active;
  if (!worker) throw new Error("오프라인 기능을 시작하지 못했습니다.");
  if (worker.state !== "activated") await new Promise<void>((resolve, reject) => {
    worker.addEventListener("statechange", () => { if (worker.state === "activated") resolve(); if (worker.state === "redundant") reject(new Error("오프라인 기능 설치 실패")); });
    signal.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")), { once: true });
  });
  const cache = await caches.open(BIBLE_CACHE);
  const assets = [...document.querySelectorAll<HTMLScriptElement | HTMLLinkElement>('script[src],link[rel="stylesheet"],link[rel="modulepreload"]')].map((el) => el instanceof HTMLScriptElement ? el.src : el.href);
  const loaded = performance.getEntriesByType("resource").map((entry) => entry.name).filter((url) => new URL(url).pathname.startsWith("/assets/") && /\.(?:js|css|woff2)(?:\?|$)/.test(url));
  for (const url of new Set(["/bible", "/bible/krv/manifest.json", ...assets, ...loaded])) {
    if (signal.aborted) throw new DOMException("Aborted", "AbortError");
    const response = await fetch(url, { signal });
    if (!response.ok || new URL(url, location.origin).origin !== location.origin) throw new Error("오프라인 화면 저장 실패");
    await cache.put(url, response);
  }
  let cursor = 1, completed = 0;
  await Promise.all(Array.from({ length: 4 }, async () => {
    while (cursor <= 1189) {
      const id = cursor++;
      const response = await fetch(`/bible/krv/${id}.json`, { signal });
      if (!response.ok) throw new Error("오프라인 본문 저장 실패");
      await decodeBibleResponse(response.clone(), id, manifest);
      if (signal.aborted) throw new DOMException("Aborted", "AbortError");
      await cache.put(`/bible/krv/${id}.json`, response); onProgress(++completed);
    }
  }));
}
