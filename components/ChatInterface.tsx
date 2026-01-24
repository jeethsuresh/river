'use client';

import { useEffect, useState, useCallback } from 'react';
import { MatrixClient, Room } from 'matrix-js-sdk';
import { Conversation, getConversations, getMessages, sendMessage, getRoomName } from '@/lib/matrixClient';
import { localStorageService, indexedDBService } from '@/lib/storage';
import ConversationList from './ConversationList';
import ChatView from './ChatView';
import styles from './ChatInterface.module.css';

interface ChatInterfaceProps {
  client: MatrixClient;
  onLogout: () => void;
}

export default function ChatInterface({ client, onLogout }: ChatInterfaceProps) {
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [selectedRoomId, setSelectedRoomId] = useState<string | null>(null);
  const [isMobile, setIsMobile] = useState(false);
  const userId = client.getUserId() || '';

  const updateConversations = useCallback(async () => {
    const convos = getConversations(client);
    setConversations(convos);
    
    // Save to IndexedDB
    if (userId) {
      await indexedDBService.saveConversations(convos, userId);
      localStorageService.setLastSyncTime(Date.now());
    }
  }, [client, userId]);

  useEffect(() => {
    // Load selected room from localStorage
    const savedRoomId = localStorageService.getSelectedRoom();
    if (savedRoomId) {
      setSelectedRoomId(savedRoomId);
    }
    
    // Load conversations from IndexedDB first for faster UI
    const loadFromStorage = async () => {
      if (userId) {
        const storedConversations = await indexedDBService.getConversations(userId);
        if (storedConversations.length > 0) {
          setConversations(storedConversations);
        }
      }
    };
    
    loadFromStorage();
    
    // Initial load from Matrix client
    updateConversations();

    // Listen for room events
    const handleRoomTimeline = (event: any, room: Room) => {
      if (room) {
        updateConversations();
      }
    };

    const handleRoom = (room: Room) => {
      updateConversations();
    };

    client.on('Room.timeline', handleRoomTimeline);
    client.on('Room', handleRoom);

    // Update conversations periodically
    const interval = setInterval(updateConversations, 5000);

    // Check mobile viewport
    const checkMobile = () => {
      setIsMobile(window.innerWidth < 768);
    };
    checkMobile();
    window.addEventListener('resize', checkMobile);

    return () => {
      client.removeListener('Room.timeline', handleRoomTimeline);
      client.removeListener('Room', handleRoom);
      clearInterval(interval);
      window.removeEventListener('resize', checkMobile);
    };
  }, [client, updateConversations, userId]);

  const handleSelectConversation = (roomId: string) => {
    setSelectedRoomId(roomId);
    // Store selected room in localStorage
    localStorageService.setSelectedRoom(roomId);
  };

  const handleSendMessage = async (message: string) => {
    if (!selectedRoomId) return;
    
    try {
      await sendMessage(client, selectedRoomId, message);
      updateConversations();
    } catch (error) {
      console.error('Failed to send message:', error);
    }
  };

  const handleBack = () => {
    setSelectedRoomId(null);
  };

  return (
    <div className={styles.container}>
      <header className={styles.header}>
        <h1 className={styles.title}>River Chat</h1>
        <div className={styles.userInfo}>
          <span className={styles.userId}>{client.getUserId()}</span>
          <button onClick={onLogout} className={styles.logoutButton}>
            Logout
          </button>
        </div>
      </header>

      <div className={styles.main}>
        <div className={`${styles.sidebar} ${isMobile && selectedRoomId ? styles.hidden : ''}`}>
          <ConversationList
            conversations={conversations}
            selectedRoomId={selectedRoomId}
            onSelectConversation={handleSelectConversation}
          />
        </div>

        <div className={`${styles.chatView} ${isMobile && !selectedRoomId ? styles.hidden : ''}`}>
          {selectedRoomId ? (
            <ChatView
              roomId={selectedRoomId}
              roomName={getRoomName(client, selectedRoomId)}
              onSendMessage={handleSendMessage}
              onBack={isMobile ? handleBack : undefined}
            />
          ) : (
            <div className={styles.emptyState}>
              <p>Select a conversation to start chatting</p>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

