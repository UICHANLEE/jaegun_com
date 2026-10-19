// Canonical Protestant reference metadata. Licensed text lives in chapter-split /bible/krv assets.
export const BIBLE_BOOKS = [
  ["창세기",50],["출애굽기",40],["레위기",27],["민수기",36],["신명기",34],["여호수아",24],["사사기",21],["룻기",4],["사무엘상",31],["사무엘하",24],["열왕기상",22],["열왕기하",25],["역대상",29],["역대하",36],["에스라",10],["느헤미야",13],["에스더",10],["욥기",42],["시편",150],["잠언",31],["전도서",12],["아가",8],["이사야",66],["예레미야",52],["예레미야애가",5],["에스겔",48],["다니엘",12],["호세아",14],["요엘",3],["아모스",9],["오바댜",1],["요나",4],["미가",7],["나훔",3],["하박국",3],["스바냐",3],["학개",2],["스가랴",14],["말라기",4],
  ["마태복음",28],["마가복음",16],["누가복음",24],["요한복음",21],["사도행전",28],["로마서",16],["고린도전서",16],["고린도후서",13],["갈라디아서",6],["에베소서",6],["빌립보서",4],["골로새서",4],["데살로니가전서",5],["데살로니가후서",3],["디모데전서",6],["디모데후서",4],["디도서",3],["빌레몬서",1],["히브리서",13],["야고보서",5],["베드로전서",5],["베드로후서",3],["요한일서",5],["요한이서",1],["요한삼서",1],["유다서",1],["요한계시록",22],
] as const;
export const BIBLE_CHAPTERS = BIBLE_BOOKS.flatMap(([book, count]) => Array.from({ length: count }, (_, index) => ({ book, chapter: index + 1 })));
export function chapterReference(id: number): string {
  const chapter = Number.isInteger(id) ? BIBLE_CHAPTERS[id - 1] : undefined;
  return chapter ? `${chapter.book} ${chapter.chapter}장` : "";
}
export function chapterID(bookIndex: number, chapter: number): number | null {
  const book = BIBLE_BOOKS[bookIndex];
  if (!Number.isInteger(bookIndex) || !book || !Number.isInteger(chapter) || chapter < 1 || chapter > book[1]) return null;
  return BIBLE_BOOKS.slice(0, bookIndex).reduce((total, [, count]) => total + count, 0) + chapter;
}
