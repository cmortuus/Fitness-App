import adapterNode from '@sveltejs/adapter-node';
import adapterStatic from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

const isCapacitor = process.env.CAPACITOR === '1';

/** @type {import('@sveltejs/kit').Config} */
const config = {
  preprocess: vitePreprocess(),
  kit: {
    adapter: isCapacitor
      ? adapterStatic({ pages: 'dist', assets: 'dist', fallback: 'index.html' })
      : adapterNode({ out: 'build', precompress: false, polyfillNode: true }),
    alias: {
      $lib: './src/lib',
      $components: './src/components',
      $pages: './src/pages',
    },
  },
};

export default config;