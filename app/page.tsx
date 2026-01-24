'use client';

import { useEffect } from 'react';
import { useRouter } from 'next/navigation';
import LoginPage from '@/components/LoginPage';
import { localStorageService } from '@/lib/storage';

export default function Home() {
  const router = useRouter();

  useEffect(() => {
    // Check if user is already logged in
    const auth = localStorageService.getAuth();

    if (auth) {
      router.push('/chat');
    }
  }, [router]);

  return <LoginPage />;
}

