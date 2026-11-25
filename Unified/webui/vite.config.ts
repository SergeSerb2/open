import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import preact from '@preact/preset-vite';
import { defineConfig } from 'vite';

const rootDir = fileURLToPath(new URL('.', import.meta.url));

export default defineConfig({
  base: '/',
  plugins: [preact()],
  resolve: {
    alias: {
      '@shared': resolve(rootDir, 'src/shared'),
    },
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    manifest: 'manifest.json',
    target: 'es2022',
    cssCodeSplit: true,
    rollupOptions: {
      input: {
        settings: resolve(rootDir, 'settings.html'),
        library: resolve(rootDir, 'library.html'),
        boosts: resolve(rootDir, 'boosts.html'),
        easel: resolve(rootDir, 'easel.html'),
        note: resolve(rootDir, 'note.html'),
        onboarding: resolve(rootDir, 'onboarding.html'),
        welcome: resolve(rootDir, 'welcome.html'),
      },
      output: {
        entryFileNames: 'assets/[name]-[hash].js',
        chunkFileNames: 'assets/chunk-[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash][extname]',
      },
    },
  },
});
