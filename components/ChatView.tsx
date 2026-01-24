'use client';

import { useEffect, useState, useRef } from 'react';
import { MatrixClient, Message, getMessages, getClient, loadOlderMessages, hasMoreMessages } from '@/lib/matrixClient';
import { indexedDBService } from '@/lib/storage';
import styles from './ChatView.module.css';

interface ChatViewProps {
  roomId: string;
  roomName: string;
  onSendMessage: (message: string) => void;
  onBack?: () => void;
}

export default function ChatView({
  roomId,
  roomName,
  onSendMessage,
  onBack,
}: ChatViewProps) {
  const [messages, setMessages] = useState<Message[]>([]);
  const [inputValue, setInputValue] = useState('');
  const [loading, setLoading] = useState(true);
  const [loadingOlder, setLoadingOlder] = useState(false);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const messagesContainerRef = useRef<HTMLDivElement>(null);
  const client = getClient();
  const userId = client?.getUserId() || '';

  const scrollToBottom = () => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  };

  useEffect(() => {
    if (!client || !userId) return;

    const loadMessages = async () => {
      // First, try to load from IndexedDB for faster UI
      const storedMessages = await indexedDBService.getMessages(roomId, userId);
      if (storedMessages.length > 0) {
        // Convert stored messages to Message format (add dummy event for compatibility)
        const messagesWithEvent = storedMessages.map((msg) => ({
          ...msg,
          event: {} as any, // Stored messages don't have event, but we don't use it in the UI
        }));
        setMessages(messagesWithEvent);
        setLoading(false);
        setTimeout(scrollToBottom, 100);
      }

      // Then load from Matrix client and update
      const msgs = getMessages(client, roomId);
      setMessages(msgs);
      setLoading(false);
      
      // Save to IndexedDB (without event property)
      if (msgs.length > 0) {
        await indexedDBService.saveMessages(
          msgs.map(({ event, ...msg }) => msg),
          roomId,
          userId
        );
      }
      
      setTimeout(scrollToBottom, 100);
    };

    loadMessages();

    // Listen for new messages
    const handleTimeline = async (event: any, room: any) => {
      if (room.roomId === roomId) {
        const msgs = getMessages(client, roomId);
        setMessages(msgs);
        
        // Save to IndexedDB
        if (userId && msgs.length > 0) {
          await indexedDBService.saveMessages(
            msgs.map(({ event, ...msg }) => msg),
            roomId,
            userId
          );
        }
      }
    };

    client.on('Room.timeline', handleTimeline);

    return () => {
      client.removeListener('Room.timeline', handleTimeline);
    };
  }, [client, roomId, userId]);

  // Handle scroll to load older messages
  useEffect(() => {
    const container = messagesContainerRef.current;
    if (!container || !client) return;

    let scrollTimeout: NodeJS.Timeout;
    let isLoading = false;

    const handleScroll = async () => {
      // Debounce scroll events
      clearTimeout(scrollTimeout);
      scrollTimeout = setTimeout(async () => {
        if (isLoading || loadingOlder) return;

        // Check if scrolled near the top (within 200px)
        if (container.scrollTop < 200) {
          const room = client.getRoom(roomId);
          if (!room) return;

          const timeline = room.getLiveTimeline();
          const paginationToken = timeline.getPaginationToken('b');
          
          // Only load if there's a pagination token (more messages available)
          if (paginationToken) {
            isLoading = true;
            setLoadingOlder(true);
            const scrollHeight = container.scrollHeight;
            const scrollTop = container.scrollTop;
            
            try {
              const success = await loadOlderMessages(client, roomId, 30);
              if (success) {
                // Reload messages to get the new ones
                const msgs = getMessages(client, roomId);
                setMessages(msgs);
                
                // Save to IndexedDB
                if (userId && msgs.length > 0) {
                  await indexedDBService.saveMessages(
                    msgs.map(({ event, ...msg }) => msg),
                    roomId,
                    userId
                  );
                }
                
                // Restore scroll position after loading
                requestAnimationFrame(() => {
                  const newScrollHeight = container.scrollHeight;
                  container.scrollTop = newScrollHeight - scrollHeight + scrollTop;
                  setLoadingOlder(false);
                  isLoading = false;
                });
              } else {
                setLoadingOlder(false);
                isLoading = false;
              }
            } catch (error) {
              console.error('Failed to load older messages:', error);
              setLoadingOlder(false);
              isLoading = false;
            }
          }
        }
      }, 150);
    };

    container.addEventListener('scroll', handleScroll);
    return () => {
      container.removeEventListener('scroll', handleScroll);
      clearTimeout(scrollTimeout);
    };
  }, [client, roomId, loadingOlder]);

  useEffect(() => {
    scrollToBottom();
  }, [messages]);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (inputValue.trim()) {
      onSendMessage(inputValue.trim());
      setInputValue('');
    }
  };

  const formatTime = (timestamp: number) => {
    const date = new Date(timestamp);
    return date.toLocaleTimeString('en-US', {
      hour: 'numeric',
      minute: '2-digit',
    });
  };

  const formatDate = (timestamp: number) => {
    const date = new Date(timestamp);
    const today = new Date();
    const yesterday = new Date(today);
    yesterday.setDate(yesterday.getDate() - 1);

    if (date.toDateString() === today.toDateString()) {
      return 'Today';
    } else if (date.toDateString() === yesterday.toDateString()) {
      return 'Yesterday';
    } else {
      return date.toLocaleDateString('en-US', {
        month: 'short',
        day: 'numeric',
        year: date.getFullYear() !== today.getFullYear() ? 'numeric' : undefined,
      });
    }
  };

  const getDisplayName = (sender: string) => {
    if (sender.startsWith('@')) {
      return sender.split(':')[0].substring(1);
    }
    return sender;
  };

  const isOwnMessage = (sender: string) => {
    return client?.getUserId() === sender;
  };

  let lastDate: string | null = null;

  return (
    <div className={styles.container}>
      <div className={styles.header}>
        {onBack && (
          <button onClick={onBack} className={styles.backButton}>
            ← Back
          </button>
        )}
        <h2 className={styles.title}>{roomName}</h2>
      </div>

      <div 
        ref={messagesContainerRef}
        className={styles.messagesContainer}
      >
        {loadingOlder && (
          <div className={styles.loadingOlder}>Loading older messages...</div>
        )}
        {loading ? (
          <div className={styles.loading}>Loading messages...</div>
        ) : messages.length === 0 ? (
          <div className={styles.empty}>No messages yet. Start the conversation!</div>
        ) : (
          messages.map((message, index) => {
            const messageDate = formatDate(message.timestamp);
            const showDate = messageDate !== lastDate;
            lastDate = messageDate;

            const own = isOwnMessage(message.sender);

            return (
              <div key={message.id || index}>
                {showDate && (
                  <div className={styles.dateDivider}>
                    <span>{messageDate}</span>
                  </div>
                )}
                <div
                  className={`${styles.message} ${own ? styles.ownMessage : ''}`}
                >
                  <div className={styles.messageContent}>
                    {!own && (
                      <div className={styles.senderName}>
                        {getDisplayName(message.sender)}
                      </div>
                    )}
                    <div className={styles.messageText}>{message.content}</div>
                    <div className={styles.messageTime}>
                      {formatTime(message.timestamp)}
                    </div>
                  </div>
                </div>
              </div>
            );
          })
        )}
        <div ref={messagesEndRef} />
      </div>

      <form onSubmit={handleSubmit} className={styles.inputContainer}>
        <input
          type="text"
          value={inputValue}
          onChange={(e) => setInputValue(e.target.value)}
          placeholder="Type a message..."
          className={styles.input}
        />
        <button type="submit" className={styles.sendButton} disabled={!inputValue.trim()}>
          Send
        </button>
      </form>
    </div>
  );
}

