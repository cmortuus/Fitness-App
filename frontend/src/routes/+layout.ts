// adapter-static (Capacitor) needs SSR off; adapter-node uses SSR.
// Both need prerender off since pages require auth.
export const prerender = false;
