import React, { createContext, useContext, useEffect, useState, useCallback } from "react";
import { api, type DbFinding } from "./api";
import type { Severity } from "./utils";

export type StoredFinding = DbFinding;

export interface NewFinding {
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
  loading: boolean;
  addFinding: (f: NewFinding) => Promise<void>;
  addMany: (fs: NewFinding[]) => Promise<void>;
  removeFinding: (id: number) => Promise<void>;
  clear: () => Promise<void>;
  reload: () => Promise<void>;
}

const FindingsContext = createContext<FindingsContextValue | null>(null);

export function FindingsProvider({ children }: { children: React.ReactNode }) {
  const [findings, setFindings] = useState<StoredFinding[]>([]);
  const [loading, setLoading] = useState(true);

  const reload = useCallback(async () => {
    try {
      const { findings } = await api.listFindings();
      setFindings(findings);
    } catch {
      /* API offline — keep current state */
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

  const addFinding = useCallback(
    async (f: NewFinding) => {
      try {
        await api.addFinding(f);
        await reload();
      } catch {
        /* ignore */
      }
    },
    [reload]
  );

  const addMany = useCallback(
    async (fs: NewFinding[]) => {
      try {
        await Promise.all(fs.map((f) => api.addFinding(f)));
        await reload();
      } catch {
        /* ignore */
      }
    },
    [reload]
  );

  const removeFinding = useCallback(
    async (id: number) => {
      setFindings((prev) => prev.filter((f) => f.id !== id));
      try {
        await api.deleteFinding(id);
      } catch {
        /* ignore */
      }
    },
    []
  );

  const clear = useCallback(async () => {
    setFindings([]);
    try {
      await api.clearFindings();
    } catch {
      /* ignore */
    }
  }, []);

  return (
    <FindingsContext.Provider
      value={{ findings, loading, addFinding, addMany, removeFinding, clear, reload }}
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
