'use client';

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { MatrixClient } from '@/lib/matrixClient';
import { setClient, startSync, createClientFromStorage } from '@/lib/matrixClient';
import { localStorageService } from '@/lib/storage';
import ChatInterface from '@/components/ChatInterface';
import styles from './chat.module.css';

export default function ChatPage() {
  const router = useRouter();
  const [client, setClientState] = useState<MatrixClient | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    // Restore client from localStorage
    const auth = localStorageService.getAuth();

    if (!auth) {
      router.push('/');
      return;
    }

    // Create async function inside useEffect
    const initializeClient = async () => {
      try {
        const restoredClient = await createClientFromStorage({
          baseUrl: auth.baseUrl,
          accessToken: auth.accessToken,
          userId: auth.userId,
          deviceId: auth.deviceId,
        });

        setClient(restoredClient);
        setClientState(restoredClient);

        // Start syncing
        startSync(restoredClient, () => {
          setLoading(false);
        });

        // Fallback timeout in case sync doesn't fire
        setTimeout(() => {
          if (restoredClient.getSyncState() === 'PREPARED') {
            setLoading(false);
          }
        }, 3000);
      } catch (err: any) {
        setError(err.message || 'Failed to restore session');
        setLoading(false);
      }
    };

    initializeClient();
  }, [router]);

  const handleLogout = async () => {
    if (client) {
      client.stopClient();
      // Clear IndexedDB data for this user
      const auth = localStorageService.getAuth();
      if (auth) {
        const { indexedDBService } = await import('@/lib/storage');
        await indexedDBService.clearAllData(auth.userId);
      }
    }
    localStorageService.clearAuth();
    setClient(null);
    router.push('/');
  };

  if (loading) {
    return (
      <div className={styles.loadingContainer}>
        <div className={styles.loading}>Connecting to Matrix...</div>
      </div>
    );
  }

  if (error) {
    return (
      <div className={styles.errorContainer}>
        <div className={styles.error}>{error}</div>
        <button onClick={() => router.push('/')} className={styles.backButton}>
          Go to Login
        </button>
      </div>
    );
  }

  if (!client) {
    return null;
  }

  return <ChatInterface client={client} onLogout={handleLogout} />;
}

