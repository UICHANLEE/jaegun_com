// Explicit local QA only. Production builds keep vite.config.ts and its CSP.
import { defineConfig, mergeConfig } from "vitest/config";
import base from "./vite.config";

export default defineConfig(({ command }) => {
  if (command !== "serve") throw new Error("Local database proxy cannot build production assets");
  return mergeConfig(base, {
    server: {
      host: "127.0.0.1", port: 5174, strictPort: true,
      proxy: Object.fromEntries(["/auth/v1", "/rest/v1", "/storage/v1", "/realtime/v1", "/functions/v1"]
        .map((path) => [path, { target: "http://127.0.0.1:54321", changeOrigin: true, ws: path === "/realtime/v1" }])),
    },
  });
});
