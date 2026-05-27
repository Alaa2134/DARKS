import React, { createContext, useContext, useEffect, useState } from "react";

export interface ScopeEntry {
  host: string;
  note: string;
  attestedAt: string;
}

interface ScopeContextValue {
  scope: ScopeEntry[];
  addScope: (host: string, note: string) => void;
  removeScope: (host: string) => void;
  hosts: string[];
}

const ScopeContext = createContext<ScopeContextValue | null>(null);
const STORAGE_KEY = "horus.scope";

export function ScopeProvider({ children }: { children: React.ReactNode }) {
  const [scope, setScope] = useState<ScopeEntry[]>(() => {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      return raw ? (JSON.parse(raw) as ScopeEntry[]) : [];
    } catch {
      return [];
    }
  });

  useEffect(() => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(scope));
  }, [scope]);

  const addScope = (host: string, note: string) => {
    const clean = host.trim().toLowerCase();
    if (!clean) return;
    setScope((prev) =>
      prev.some((s) => s.host === clean)
        ? prev
        : [...prev, { host: clean, note, attestedAt: new Date().toISOString() }]
    );
  };

  const removeScope = (host: string) =>
    setScope((prev) => prev.filter((s) => s.host !== host));

  return (
    <ScopeContext.Provider
      value={{ scope, addScope, removeScope, hosts: scope.map((s) => s.host) }}
    >
      {children}
    </ScopeContext.Provider>
  );
}

export function useScope() {
  const ctx = useContext(ScopeContext);
  if (!ctx) throw new Error("useScope must be used within ScopeProvider");
  return ctx;
}
