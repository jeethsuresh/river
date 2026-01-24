'use client';

import { Conversation } from '@/lib/matrixClient';
import styles from './ConversationList.module.css';

interface ConversationListProps {
  conversations: Conversation[];
  selectedRoomId: string | null;
  onSelectConversation: (roomId: string) => void;
}

export default function ConversationList({
  conversations,
  selectedRoomId,
  onSelectConversation,
}: ConversationListProps) {
  const formatTime = (timestamp: number) => {
    const date = new Date(timestamp);
    const now = new Date();
    const diff = now.getTime() - date.getTime();
    const days = Math.floor(diff / (1000 * 60 * 60 * 24));

    if (days === 0) {
      return date.toLocaleTimeString('en-US', {
        hour: 'numeric',
        minute: '2-digit',
      });
    } else if (days === 1) {
      return 'Yesterday';
    } else if (days < 7) {
      return date.toLocaleDateString('en-US', { weekday: 'short' });
    } else {
      return date.toLocaleDateString('en-US', {
        month: 'short',
        day: 'numeric',
      });
    }
  };

  const getDisplayName = (conversation: Conversation) => {
    // Remove @ and domain for display
    if (conversation.name.startsWith('@')) {
      return conversation.name.split(':')[0].substring(1);
    }
    return conversation.name;
  };

  return (
    <div className={styles.container}>
      <div className={styles.header}>
        <h2 className={styles.title}>Conversations</h2>
      </div>
      <div className={styles.list}>
        {conversations.length === 0 ? (
          <div className={styles.empty}>No conversations yet</div>
        ) : (
          conversations.map((conversation) => (
            <div
              key={conversation.roomId}
              className={`${styles.conversationItem} ${
                selectedRoomId === conversation.roomId ? styles.selected : ''
              }`}
              onClick={() => onSelectConversation(conversation.roomId)}
            >
              <div className={styles.avatar}>
                {conversation.avatarUrl ? (
                  <img
                    src={conversation.avatarUrl}
                    alt={getDisplayName(conversation)}
                  />
                ) : (
                  <div className={styles.avatarPlaceholder}>
                    {getDisplayName(conversation).charAt(0).toUpperCase()}
                  </div>
                )}
              </div>
              <div className={styles.content}>
                <div className={styles.topRow}>
                  <span className={styles.name}>
                    {getDisplayName(conversation)}
                  </span>
                  {conversation.lastEventTime > 0 && (
                    <span className={styles.time}>
                      {formatTime(conversation.lastEventTime)}
                    </span>
                  )}
                </div>
                {conversation.unreadCount > 0 && (
                  <div className={styles.unreadBadge}>
                    {conversation.unreadCount}
                  </div>
                )}
              </div>
            </div>
          ))
        )}
      </div>
    </div>
  );
}

