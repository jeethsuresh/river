'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { login, setClient } from '@/lib/matrixClient';
import { localStorageService } from '@/lib/storage';
import styles from './LoginPage.module.css';

export default function LoginPage() {
  const router = useRouter();
  const [baseUrl, setBaseUrl] = useState('https://matrix.org');
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');
    setLoading(true);

    try {
      const client = await login({
        baseUrl,
        username,
        password,
      });

      // Store credentials using storage service
      localStorageService.setAuth({
        accessToken: client.getAccessToken() || '',
        userId: client.getUserId() || '',
        baseUrl,
        deviceId: client.getDeviceId() || undefined,
      });

      setClient(client);
      router.push('/chat');
    } catch (err: any) {
      setError(err.message || 'Login failed. Please check your credentials.');
      setLoading(false);
    }
  };

  return (
    <div className={styles.container}>
      <div className={styles.loginBox}>
        <h1 className={styles.title}>River Chat</h1>
        <p className={styles.subtitle}>Matrix Client</p>
        
        <form onSubmit={handleSubmit} className={styles.form}>
          <div className={styles.formGroup}>
            <label htmlFor="baseUrl">Matrix Server</label>
            <input
              id="baseUrl"
              type="text"
              value={baseUrl}
              onChange={(e) => setBaseUrl(e.target.value)}
              placeholder="https://matrix.org"
              required
            />
          </div>

          <div className={styles.formGroup}>
            <label htmlFor="username">Username</label>
            <input
              id="username"
              type="text"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              placeholder="@username:matrix.org"
              required
            />
          </div>

          <div className={styles.formGroup}>
            <label htmlFor="password">Password</label>
            <input
              id="password"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="Password"
              required
            />
          </div>

          {error && <div className={styles.error}>{error}</div>}

          <button
            type="submit"
            className={styles.submitButton}
            disabled={loading}
          >
            {loading ? 'Logging in...' : 'Login'}
          </button>
        </form>
      </div>
    </div>
  );
}

