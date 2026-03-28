import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
const oauthToken = process.env.CLAUDE_CODE_OAUTH_TOKEN || '';

export default defineConfig({
  plugins: [react()],
  define: {
    'import.meta.env.VITE_OAUTH_TOKEN': JSON.stringify(oauthToken),
  },
  server: {
    proxy: {
      '/api': {
        target: 'https://api.anthropic.com',
        changeOrigin: true,
        configure: (proxy) => {
          proxy.on('proxyReq', (proxyReq) => {
            // If no Authorization header from client, inject the OAuth token server-side
            if (oauthToken && !proxyReq.getHeader('authorization')?.includes('eyJ')) {
              proxyReq.setHeader('Authorization', `Bearer ${oauthToken}`);
            }
          });
        },
      }
    }
  }
})
