import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'dev.lethal.gymtracker',
  appName: 'GymTracker',
  webDir: 'dist',
  server: {
    // Load from the live server — the app is a native wrapper
    // with access to HealthKit and other native APIs.
    // For local dev, change this to http://localhost:5173
    url: 'https://lethal.dev',
    cleartext: false,
  },
  ios: {
    scheme: 'GymTracker',
    contentInset: 'automatic',
  },
};

export default config;
