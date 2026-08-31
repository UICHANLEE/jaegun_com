import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    host: "0.0.0.0",
    allowedHosts: ["terminal.local"],
  },
  build: {
    target: "es2022",
    sourcemap: false,
    rollupOptions: {
      treeshake: {
        moduleSideEffects: (id) => !/[\\/]src[\\/]data[\\/]seed\.ts$/u.test(id),
      },
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: "./src/test/setup.ts",
  },
});
