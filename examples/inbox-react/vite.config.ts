import { defineConfig } from "vite";

export default defineConfig({
  resolve: { dedupe: ["react", "react-dom", "@fyrlet/client"] },
  server: { fs: { allow: ["../.."] } },
});
