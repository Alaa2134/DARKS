/**
 * retriever.ts — dependency-free TF-IDF retrieval over the knowledge corpus.
 * Returns the most relevant passages for a query so the LLM (or the offline
 * responder) can answer with grounded, citeable context.
 */

import { KNOWLEDGE, type KnowledgeDoc } from "./corpus";

function tokenize(text: string): string[] {
  return (text.toLowerCase().match(/[a-z0-9]+/g) ?? []).filter((t) => t.length > 1);
}

interface IndexedDoc {
  doc: KnowledgeDoc;
  tf: Map<string, number>;
  length: number;
}

const N = KNOWLEDGE.length;
const docFreq = new Map<string, number>();
const indexed: IndexedDoc[] = KNOWLEDGE.map((doc) => {
  const tokens = tokenize(`${doc.title} ${doc.tags.join(" ")} ${doc.text}`);
  const tf = new Map<string, number>();
  for (const t of tokens) tf.set(t, (tf.get(t) ?? 0) + 1);
  for (const term of tf.keys()) docFreq.set(term, (docFreq.get(term) ?? 0) + 1);
  return { doc, tf, length: tokens.length };
});

function idf(term: string): number {
  const df = docFreq.get(term) ?? 0;
  return Math.log((N + 1) / (df + 1)) + 1;
}

export interface RetrievedDoc {
  id: string;
  title: string;
  source: string;
  text: string;
  score: number;
}

export function retrieve(query: string, k = 4): RetrievedDoc[] {
  const qTokens = tokenize(query);
  if (qTokens.length === 0) return [];
  const qTf = new Map<string, number>();
  for (const t of qTokens) qTf.set(t, (qTf.get(t) ?? 0) + 1);

  const scored = indexed.map(({ doc, tf, length }) => {
    let score = 0;
    for (const [term, qCount] of qTf) {
      const dCount = tf.get(term);
      if (!dCount) continue;
      const w = idf(term);
      score += (qCount * w) * ((dCount / length) * w);
    }
    return {
      id: doc.id,
      title: doc.title,
      source: doc.source,
      text: doc.text,
      score,
    };
  });

  return scored
    .filter((s) => s.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, k);
}

/** Format retrieved docs as a context block for prompt injection. */
export function buildContext(query: string, k = 4): { context: string; sources: RetrievedDoc[] } {
  const sources = retrieve(query, k);
  if (sources.length === 0) return { context: "", sources: [] };
  const context = sources
    .map((s) => `[${s.id}] ${s.title} (${s.source})\n${s.text}`)
    .join("\n\n");
  return { context, sources };
}
