import { defineConfig } from 'astro/config';

import cloudflare from "@astrojs/cloudflare";

export default defineConfig({
  site: 'https://getkoji.dev',

  server: {
    port: 4321,
  },

  output: "hybrid",
  adapter: cloudflare()
});