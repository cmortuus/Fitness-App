import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'dev.lethal.gymtracker',
  appName: 'GymTracker',
  webDir: 'dist',
  // No server.url — app loads from local bundle.
  // Build with: cd frontend && npm run build && npx cap sync ios
  ios: {
    scheme: 'GymTracker',
    contentInset: 'automatic',
  },
};

export default config;
