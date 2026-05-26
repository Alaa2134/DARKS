import React, { createContext, useContext, useEffect, useState } from "react";
import type { Severity } from "./utils";

export interface StoredFinding {
  id: string;
  title: string;
  severity: Severity;
  description: string;
  impact?: string;
  remediation?: string;
  evidence?: string;
  source: "audit" | "code-review" | "log" | "manual";
}

interface FindingsContextValue {
  findings: StoredFinding[];
  addFinding: (f: Omit<StoredFinding, "id">) => void;
  addMany: (fs: Omit<StoredFinding, "id">[]) => void;
  removeFinding: (id: string) => void;
  clear: () => void;
}

const FindingsContext = createContext<FindingsContextValue | null>(null);
const STORAGE_KEY = "horus.findings";

export function FindingsProvider({ children }: { children: React.ReactNode }) {
  const [findings, setFindings] = useState<StoredFinding[]>(() => {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      return raw ? (JSON.parse(raw) as StoredFinding[]) : [];
    } catch {
      return [];
    }
  });

  useEffect(() => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(findings));
  }, [findings]);

  const makeId = () =>
    `f_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 7)}`;

  const addFinding = (f: Omit<StoredFinding, "id">) =>
    setFindings((prev) => [...prev, { ...f, id: makeId() }]);

  const addMany = (fs: Omit<StoredFinding, "id">[]) =>
    setFindings((prev) => [
      ...prev,
      ...fs.map((f) => ({ ...f, id: makeId() })),
    ]);

  const removeFinding = (id: string) =>
    setFindings((prev) => prev.filter((f) => f.id !== id));

  const clear = () => setFindings([]);

  return (
    <FindingsContext.Provider
      value={{ findings, addFinding, addMany, removeFinding, clear }}
    >
      {children}
    </FindingsContext.Provider>
  );
}

export function useFindings() {
  const ctx = useContext(FindingsContext);
  if (!ctx) throw new Error("useFindings must be used within FindingsProvider");
  return ctx;
}
