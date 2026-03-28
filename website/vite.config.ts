import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { defineConfig } from "vite";

const here = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  resolve: {
    alias: {
      "@": resolve(here, "src"),
      "@adapters": resolve(here, "../Sources/API2FileCore/Resources/Adapters")
    }
  },
  server: {
    fs: {
      allow: [resolve(here, "..")]
    }
  },
  test: {
    environment: "node",
    include: ["src/**/*.test.ts"]
  }
});
