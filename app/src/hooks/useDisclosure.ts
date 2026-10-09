"use client";

import { useCallback, useSyncExternalStore } from "react";

const KEY = "goldbench.riskDisclosure.v1";
const EVENT = "goldbench:disclosure";

function read(): boolean {
  try {
    return window.localStorage.getItem(KEY) === "accepted";
  } catch {
    return false;
  }
}

function subscribe(cb: () => void) {
  window.addEventListener("storage", cb);
  window.addEventListener(EVENT, cb);
  return () => {
    window.removeEventListener("storage", cb);
    window.removeEventListener(EVENT, cb);
  };
}

/** Risk-disclosure acceptance, persisted in localStorage and synced across components/tabs. */
export function useDisclosure() {
  const accepted = useSyncExternalStore(subscribe, read, () => false);
  const setAccepted = useCallback((v: boolean) => {
    try {
      if (v) window.localStorage.setItem(KEY, "accepted");
      else window.localStorage.removeItem(KEY);
    } catch {
      /* storage blocked: acceptance only lasts for this render cycle */
    }
    window.dispatchEvent(new Event(EVENT));
  }, []);
  return { accepted, setAccepted };
}
