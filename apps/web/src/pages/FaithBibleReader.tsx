import { useEffect, useRef, useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { ArrowLeft } from "@phosphor-icons/react";
import { BIBLE_BOOKS, BIBLE_CHAPTERS, chapterID } from "../data/bibleCanon";
import { BIBLE_CACHE, loadBibleChapter, loadBibleManifest, packageBibleOffline, type BibleChapter, type BibleManifest } from "../data/faithBible";
import { searchBibleText, type BibleSearchHit } from "../data/faithBibleSearch";
import "./faith.css";

export function FaithBiblePage() {
  return <main className="faith-page"><header className="page-toolbar"><Link to="/app/faith" className="button button--quiet" aria-label="통독·QT로 돌아가기"><ArrowLeft aria-hidden="true" /></Link><h1>성경 읽기</h1></header><FaithBibleReader /></main>;
}

export function FaithBibleReader() {
  const [parameters] = useSearchParams();
  const requestedID = Number(parameters.get("chapter"));
  const initial = BIBLE_CHAPTERS[requestedID - 1];
  const [manifest, setManifest] = useState<BibleManifest | null>(null);
  const [book, setBook] = useState(initial ? BIBLE_BOOKS.findIndex(([name]) => name === initial.book) : 0), [chapter, setChapter] = useState(initial?.chapter ?? 1);
  const [search, setSearch] = useState("");
  const [text, setText] = useState<BibleChapter | null>(null);
  const [verse, setVerse] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [progress, setProgress] = useState<number | null>(null);
  const [offline, setOffline] = useState(false);
  const download = useRef<AbortController | null>(null);
  const searchRequest = useRef<AbortController | null>(null);
  const [searchProgress, setSearchProgress] = useState<number | null>(null);
  const [searchResult, setSearchResult] = useState<{ hits: BibleSearchHit[]; total: number } | null>(null);
  const id = chapterID(book, chapter)!;
  useEffect(() => {
    const target = BIBLE_CHAPTERS[requestedID - 1];
    if (target) { setBook(BIBLE_BOOKS.findIndex(([name]) => name === target.book)); setChapter(target.chapter); }
  }, [requestedID]);
  useEffect(() => {
    const controller = new AbortController();
    void loadBibleManifest(controller.signal).then(setManifest).catch(() => { if (!controller.signal.aborted) setError("성경 출처 정보를 불러오지 못했습니다."); });
    return () => { controller.abort(); download.current?.abort(); searchRequest.current?.abort(); };
  }, []);
  useEffect(() => {
    if (!manifest) return;
    const controller = new AbortController(); setText(null); setVerse(null); setError(null);
    void loadBibleChapter(id, manifest, controller.signal).then((value) => { if (!controller.signal.aborted) setText(value); }).catch((reason: unknown) => { if (!controller.signal.aborted) setError(reason instanceof Error ? reason.message : "본문을 불러오지 못했습니다."); });
    return () => controller.abort();
  }, [id, manifest]);
  async function saveOffline() {
    if (!manifest || download.current) return;
    const controller = new AbortController(); download.current = controller; setProgress(0); setError(null);
    try { await packageBibleOffline(manifest, setProgress, controller.signal); if (!controller.signal.aborted) { setOffline(true); await navigator.storage?.persist?.(); } }
    catch (reason) { if (!controller.signal.aborted) setError(reason instanceof Error ? reason.message : "오프라인 저장 실패"); controller.abort(); }
    finally { if (download.current === controller) { download.current = null; setProgress(null); } }
  }
  async function removeOffline() {
    download.current?.abort(); download.current = null; setProgress(null);
    if ("caches" in window) await caches.delete(BIBLE_CACHE);
    setOffline(false);
  }
  async function searchAll() {
    if (!manifest || searchRequest.current) return;
    const controller = new AbortController(); searchRequest.current = controller; setSearchProgress(0); setSearchResult(null); setError(null);
    try { const result = await searchBibleText(search, manifest, setSearchProgress, controller.signal); if (!controller.signal.aborted) setSearchResult(result); }
    catch (reason) { if (!controller.signal.aborted) setError(reason instanceof Error ? reason.message : "전체 본문 검색 실패"); controller.abort(); }
    finally { if (searchRequest.current === controller) { searchRequest.current = null; setSearchProgress(null); } }
  }
  const query = search.trim().toLocaleLowerCase("ko");
  const books = BIBLE_BOOKS.map(([name], index) => ({ name, index })).filter((item) => !query || item.name.includes(query));
  return <section aria-labelledby="bible-reader-title">
    <h2 id="bible-reader-title">성경 읽기 · 개역한글</h2>
    <p>대한성서공회 번역 · CrossWire KorRV 2.0.1 (1952/1961, Wikisource). 개역개정이 아닙니다.</p>
    <p><strong>절 번호는 원본 CrossWire 모듈의 NRSV 좌표입니다.</strong> 합절 때문에 인쇄 개역한글과 절 번호가 다를 수 있습니다. 예: 고후 13:14의 축도는 이 모듈의 13:13에 포함됩니다. 빈 절은 인접 절을 함께 확인해 주세요.</p>
    <label className="field"><span>성경 책 이름 또는 현재 장 본문 검색</span><input type="search" value={search} onChange={(event) => setSearch(event.target.value)} /></label>
    <button className="button button--secondary" disabled={!manifest || searchProgress !== null || Array.from(search.trim()).length < 2} onClick={() => void searchAll()}>성경 전체 본문 검색</button>
    {searchProgress !== null ? <p role="status">전체 본문 검색 중 · {searchProgress} / 1,189장</p> : null}
    {searchResult ? <div><p>전체 {searchResult.total}절 일치 · 성경 순서로 최대 200개 표시</p><ul className="faith-qt-list">{searchResult.hits.map((hit) => <li key={`${hit.id}:${hit.verse}`}><button className="button button--quiet" onClick={() => { setBook(hit.book); setChapter(hit.chapter); setSearch(""); setSearchResult(null); }}>{hit.reference}:{hit.verse} · {hit.text}</button></li>)}</ul></div> : null}
    {query && books.length ? <div className="faith-actions">{books.map(({ name, index }) => <button type="button" className="button button--quiet" key={name} onClick={() => { setBook(index); setChapter(1); setSearch(""); }}>{name}</button>)}</div> : null}
    <div className="faith-fields"><label className="field"><span>성경 책</span><select value={book} onChange={(event) => { setBook(Number(event.target.value)); setChapter(1); }}>{BIBLE_BOOKS.map(([name], index) => <option key={name} value={index}>{name}</option>)}</select></label><label className="field"><span>성경 장</span><select value={chapter} onChange={(event) => setChapter(Number(event.target.value))}>{Array.from({ length: BIBLE_BOOKS[book][1] }, (_, index) => <option key={index} value={index + 1}>{index + 1}장</option>)}</select></label></div>
    {error ? <p role="alert">{error}</p> : null}
    {text ? <><h3>{text.reference}</h3><ol className="faith-bible-verses">{text.verses.filter((item) => !query || item.text.toLocaleLowerCase("ko").includes(query)).map((item) => <li key={item.verse} value={item.verse}><button className="button button--quiet" aria-pressed={verse === item.verse} onClick={() => setVerse(item.verse)}>{item.text || "원본 모듈에 독립 절 본문 없음 (합절·생략·절 좌표 차이). 인접 절을 확인해 주세요."}</button></li>)}</ol>{query && !text.verses.some((item) => item.text.toLocaleLowerCase("ko").includes(query)) ? <p>현재 장에서 일치하는 본문이 없습니다.</p> : null}</> : !error ? <p role="status">본문을 불러오는 중입니다.</p> : null}
    <div className="faith-actions"><button className="button button--secondary" disabled={!manifest || progress !== null} onClick={() => void saveOffline()}>전체 1,189장 오프라인 저장</button><button className="button button--quiet" onClick={() => void removeOffline()}>오프라인 자료 삭제</button></div>
    {progress !== null ? <p role="status">공개 성경 저장 중 · {progress} / 1,189장</p> : offline ? <p role="status">전체 본문을 저장했습니다. <Link to="/bible">오프라인 성경 읽기 화면</Link>에서 연결 없이 읽을 수 있습니다. 브라우저 저장 공간 정리 시 삭제될 수 있습니다.</p> : null}
    <details><summary>판본·저작권·본문 한계</summary><p>{manifest?.attribution} · {manifest?.license}. 원본 모듈의 합절·생략과 NRSV 절 좌표를 그대로 유지하며 번역문을 보충·개작하지 않습니다. 대한성서공회 공식 정본 인증을 뜻하지 않습니다. 입력 즉시 검색은 현재 장 대상이며 전체 검색 버튼은 성경 전체 본문에서 찾습니다.</p><a href="https://www.bskorea.or.kr/bbs/board.php?bo_table=copyright_faq&wr_id=5" target="_blank" rel="noreferrer">대한성서공회 이용 안내</a>{manifest ? <p><a href={manifest.source} target="_blank" rel="noreferrer">원본 모듈과 Public Domain 배포 조건</a></p> : null}</details>
  </section>;
}
