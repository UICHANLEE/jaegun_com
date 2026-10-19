import { loadBibleChapter, type BibleManifest } from "./faithBible";
export interface BibleSearchHit { id: number; book: number; chapter: number; reference: string; verse: number; text: string }
export async function searchBibleText(query: string, manifest: BibleManifest, onProgress: (count: number) => void, signal: AbortSignal): Promise<{ hits: BibleSearchHit[]; total: number }> {
  const needle = query.trim().toLocaleLowerCase("ko");
  if (Array.from(needle).length < 2 || Array.from(needle).length > 100) throw new Error("전체 본문 검색어는 2~100자로 입력해 주세요.");
  let cursor = 1, completed = 0, total = 0;
  const hits: BibleSearchHit[] = [];
  await Promise.all(Array.from({ length: 4 }, async () => {
    while (cursor <= 1189) {
      if (signal.aborted) throw new DOMException("Aborted", "AbortError");
      const chapter = await loadBibleChapter(cursor++, manifest, signal);
      for (const verse of chapter.verses) {
        if (!verse.text.toLocaleLowerCase("ko").includes(needle)) continue;
        total += 1;
        // Keep canonical first200, regardless of parallel chapter completion order.
        hits.push({ id: chapter.id, book: chapter.book, chapter: chapter.chapter, reference: chapter.reference, verse: verse.verse, text: verse.text });
      }
      hits.sort((a, b) => a.id - b.id || a.verse - b.verse);
      if (hits.length > 200) hits.length = 200;
      onProgress(++completed);
    }
  }));
  return { hits, total };
}
