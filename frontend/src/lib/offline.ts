/**
 * Offline support — IndexedDB queue for pending API requests
 * and session snapshots for page reload recovery.
 */

const DB_NAME = 'gymtracker-offline';
const DB_VERSION = 1;
const QUEUE_STORE = 'request-queue';

interface QueuedRequest {
  id: string;
  method: string;
  url: string;
  body: string | null;
  timestamp: number;
  retries: number;
  status: 'pending' | 'syncing' | 'failed';
}

let db: IDBDatabase | null = null;

function openDB(): Promise<IDBDatabase> {
  if (db) return Promise.resolve(db);
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(QUEUE_STORE)) {
        database.createObjectStore(QUEUE_STORE, { keyPath: 'id' });
      }
    };
    request.onsuccess = () => {
      db = request.result;
      resolve(db);
    };
    request.onerror = () => reject(request.error);
  });
}

/** Add a failed request to the offline queue */
export async function queueRequest(method: string, url: string, body: any): Promise<void> {
  const database = await openDB();
  const tx = database.transaction(QUEUE_STORE, 'readwrite');
  const store = tx.objectStore(QUEUE_STORE);
  const entry: QueuedRequest = {
    id: crypto.randomUUID(),
    method,
    url,
    body: body ? JSON.stringify(body) : null,
    timestamp: Date.now(),
    retries: 0,
    status: 'pending',
  };
  store.add(entry);
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

/** Get all pending requests from the queue */
export async function getPendingRequests(): Promise<QueuedRequest[]> {
  const database = await openDB();
  const tx = database.transaction(QUEUE_STORE, 'readonly');
  const store = tx.objectStore(QUEUE_STORE);
  const request = store.getAll();
  return new Promise((resolve, reject) => {
    request.onsuccess = () => {
      const all = request.result as QueuedRequest[];
      resolve(all.filter(r => r.status === 'pending').sort((a, b) => a.timestamp - b.timestamp));
    };
    request.onerror = () => reject(request.error);
  });
}

/** Remove a request from the queue after successful sync */
export async function removeRequest(id: string): Promise<void> {
  const database = await openDB();
  const tx = database.transaction(QUEUE_STORE, 'readwrite');
  tx.objectStore(QUEUE_STORE).delete(id);
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}

/** Get count of pending requests */
export async function getPendingCount(): Promise<number> {
  const pending = await getPendingRequests();
  return pending.length;
}

/** Replay all pending requests (called when back online) */
export async function syncPendingRequests(
  onProgress?: (done: number, total: number) => void
): Promise<{ synced: number; failed: number }> {
  const pending = await getPendingRequests();
  if (pending.length === 0) return { synced: 0, failed: 0 };

  let synced = 0;
  let failed = 0;
  const token = typeof localStorage !== 'undefined'
    ? localStorage.getItem('hgt_access_token')
    : null;

  for (const req of pending) {
    try {
      const headers: Record<string, string> = { 'Content-Type': 'application/json' };
      if (token) headers['Authorization'] = `Bearer ${token}`;

      const response = await fetch(req.url, {
        method: req.method,
        headers,
        body: req.body,
      });

      if (response.ok || response.status === 204) {
        await removeRequest(req.id);
        synced++;
      } else if (response.status === 401) {
        // Token expired — stop syncing, user needs to re-auth
        failed++;
        break;
      } else if (response.status >= 400 && response.status < 500) {
        // Client error (404 deleted resource, 422 validation, etc.) —
        // this request will never succeed, discard it.
        await removeRequest(req.id);
        failed++;
      } else {
        // Server error (5xx) — keep for retry
        failed++;
      }
    } catch {
      // Network still down
      failed++;
      break;
    }
    onProgress?.(synced + failed, pending.length);
  }

  return { synced, failed };
}

/** Clear all queued requests (for testing/reset) */
export async function clearQueue(): Promise<void> {
  const database = await openDB();
  const tx = database.transaction(QUEUE_STORE, 'readwrite');
  tx.objectStore(QUEUE_STORE).clear();
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}
