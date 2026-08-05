import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach } from "vitest";

const localStorageValues = new Map<string, string>();

const localStorageMock: Storage = {
  get length() {
    return localStorageValues.size;
  },
  clear() {
    localStorageValues.clear();
  },
  getItem(key) {
    return localStorageValues.get(key) ?? null;
  },
  key(index) {
    return Array.from(localStorageValues.keys())[index] ?? null;
  },
  removeItem(key) {
    localStorageValues.delete(key);
  },
  setItem(key, value) {
    localStorageValues.set(key, value);
  },
};

Object.defineProperty(window, "localStorage", {
  configurable: true,
  value: localStorageMock,
});

afterEach(() => {
  cleanup();
  window.localStorage.clear();
  window.sessionStorage.clear();
});
