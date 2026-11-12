import { defineConfig } from "vite";

// Tauri 要求固定端口，且不能自动改端口
export default defineConfig({
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    watch: { ignored: ["**/src-tauri/**"] },
  },
  build: {
    target: "safari13",
    minify: "esbuild",
    sourcemap: false,
  },
});
