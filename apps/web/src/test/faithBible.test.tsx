import { webcrypto } from "node:crypto";
import { describe, expect, it, vi, afterEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router-dom";
import { FaithBibleReader } from "../pages/FaithBibleReader";
import { BIBLE_BOOKS, chapterID } from "../data/bibleCanon";
import { parseBibleChapter, type BibleManifest, type BibleChapter } from "../data/faithBible";
import { searchBibleText } from "../data/faithBibleSearch";
import manifestText from "../../public/bible/krv/manifest.json?raw";
import genesisText from "../../public/bible/krv/1.json?raw";
const chapterFiles = import.meta.glob<string>("../../public/bible/krv/*.json", { query: "?raw", import: "default", eager: true });
const manifest = JSON.parse(manifestText) as BibleManifest;
const genesis = JSON.parse(genesisText) as BibleChapter;
afterEach(() => vi.unstubAllGlobals());
describe("licensed Korean source packaging", () => {
  it("retains exact source identity and every real chapter hash", async () => {
    expect(manifest.id).toBe("korrv-2.0.1"); expect(manifest.archive_sha256).toBe("194dd52ceabdefb97a60f6627de22e97990e0a43b1b388caf4013d010884ecd7");
    expect(manifest.attribution).toContain("대한성서공회"); expect(manifest.attribution).toContain("CrossWire KorRV 2.0.1");
    expect(manifest.license).toContain("Public Domain"); expect(manifest.source).toBe("https://www.crosswire.org/sword/modules/ModInfo.jsp?modName=KorRV");
    expect(manifest.chapters).toHaveLength(1189);
    let slots = 0, empty = 0;
    for (const entry of manifest.chapters) {
      const source = chapterFiles[`../../public/bible/krv/${entry.id}.json`];
      expect(source).toBeTypeOf("string");
      const chapter = parseBibleChapter(JSON.parse(source), entry.id);
      expect(chapter.verses).toHaveLength(entry.verses);
      const hash = Array.from(new Uint8Array(await webcrypto.subtle.digest("SHA-256", new TextEncoder().encode(source))), (v) => v.toString(16).padStart(2, "0")).join("");
      expect(hash).toBe(entry.sha256); slots += entry.verses; empty += chapter.verses.filter((verse) => !verse.text.trim()).length;
    }
    expect(slots).toBe(31104); expect(empty).toBe(20);
    expect(genesis.verses[0].text).toBe("태초에 하나님이 천지를 창조하시니라 ");
    expect(BIBLE_BOOKS.map(([, count], index) => chapterID(index, count)).at(-1)).toBe(1189);
  });
  it("preserves upstream merged text rather than calling conversion losses omitted verses", () => {
    for (const [book, chapter, mergedIndex, emptyIndex, phrase] of [
      ["이사야", 30, 0, 1, "그들이 바로의 세력 안에서"],
      ["로마서", 9, 0, 1, "내게 큰 근심이 있는 것과 마음에 그치지 않는 고통"],
      ["고린도후서", 13, 12, 13, "주 예수 그리스도의 은혜와 하나님의 사랑과 성령의 교통하심"],
    ] as const) {
      const id = chapterID(BIBLE_BOOKS.findIndex(([name]) => name === book), chapter)!;
      const value = parseBibleChapter(JSON.parse(chapterFiles[`../../public/bible/krv/${id}.json`]), id);
      expect(value.verses[mergedIndex].text).toContain(phrase);
      expect(value.verses[emptyIndex].text).toBe("");
    }
  });
  it("rejects invented coordinates or malformed verse sequences", () => {
    expect(() => parseBibleChapter({ ...genesis, id: 2 }, 1)).toThrow();
    expect(() => parseBibleChapter({ ...genesis, reference: "창세기 2장" }, 1)).toThrow();
    expect(() => parseBibleChapter({ ...genesis, verses: [{ verse: 2, text: "본문" }] }, 1)).toThrow();
  });
  it("searches all packaged chapters rather than an invented or current-chapter-only corpus", async () => {
    Object.defineProperty(globalThis.crypto, "subtle", { configurable: true, value: webcrypto.subtle });
    const fetcher = vi.fn(async (url: string) => new Response(chapterFiles[`../../public${url}`], { status: 200 })); vi.stubGlobal("fetch", fetcher);
    const progress = vi.fn(), controller = new AbortController();
    const result = await searchBibleText("태초에", manifest, progress, controller.signal);
    expect(result.total).toBeGreaterThan(1); expect(result.hits[0].id).toBe(1); expect(result.hits[0].verse).toBe(1);
    expect(result.hits.every((hit) => hit.text.includes("태초에"))).toBe(true);
    expect(progress).toHaveBeenLastCalledWith(1189); expect(fetcher).toHaveBeenCalledTimes(1189);
    await expect(searchBibleText("한", manifest, progress, controller.signal)).rejects.toThrow();
  });
  it("reads real text without private consent and never prepares an AI request", async () => {
    Object.defineProperty(globalThis.crypto, "subtle", { configurable: true, value: webcrypto.subtle });
    const fetcher = vi.fn(async (input: string) => new Response(input.endsWith("manifest.json") ? manifestText : genesisText, { status: 200 })); vi.stubGlobal("fetch", fetcher);
    function Location() { const location = useLocation(); return <output data-testid="ai-state">{JSON.stringify(location.state)}</output>; }
    render(<MemoryRouter><FaithBibleReader /><Location /></MemoryRouter>);
    fireEvent.click(await screen.findByRole("button", { name: genesis.verses[0].text.trim() }));
    expect(screen.queryByRole("link", { name: /AI 질문 준비/ })).not.toBeInTheDocument();
    expect(screen.getByTestId("ai-state")).toHaveTextContent("null");
    expect(fetcher.mock.calls.every(([url]) => url.startsWith("/bible/krv/"))).toBe(true);
  });
  it("opens the actual chapter selected by a home daily-target link", async () => {
    Object.defineProperty(globalThis.crypto, "subtle", { configurable: true, value: webcrypto.subtle });
    const fetcher = vi.fn(async (url: string) => new Response(url.endsWith("manifest.json") ? manifestText : chapterFiles[`../../public${url}`], { status: 200 })); vi.stubGlobal("fetch", fetcher);
    render(<MemoryRouter initialEntries={["/bible?chapter=1189"]}><FaithBibleReader /></MemoryRouter>);
    expect(await screen.findByRole("heading", { name: "요한계시록 22장" })).toBeVisible();
    expect(fetcher).toHaveBeenCalledWith("/bible/krv/1189.json", expect.any(Object));
  });
});
