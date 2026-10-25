import { defineConfig } from 'vitest/config';

const DAEMON = process.env.BRAIN_CONSOLE_DAEMON ?? 'http://127.0.0.1:7474';

export default defineConfig({
  server: {
    proxy: {
      '/api': { target: DAEMON, changeOrigin: false },
      '/healthz': { target: DAEMON, changeOrigin: false },
    },
  },
  build: { outDir: 'dist', emptyOutDir: true },
  test: { environment: 'jsdom', include: ['test/**/*.test.ts', 'test/**/*.test.tsx'] },
});
