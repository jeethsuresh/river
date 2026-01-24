// Storage utilities for localStorage and IndexedDB

// ==================== localStorage helpers ====================

const STORAGE_KEYS = {
  ACCESS_TOKEN: 'matrix_access_token',
  USER_ID: 'matrix_user_id',
  BASE_URL: 'matrix_base_url',
  DEVICE_ID: 'matrix_device_id',
  SELECTED_ROOM_ID: 'selected_room_id',
  LAST_SYNC_TIME: 'last_sync_time',
} as const;

export const localStorageService = {
  // Auth storage
  setAuth: (data: {
    accessToken: string;
    userId: string;
    baseUrl: string;
    deviceId?: string;
  }) => {
    localStorage.setItem(STORAGE_KEYS.ACCESS_TOKEN, data.accessToken);
    localStorage.setItem(STORAGE_KEYS.USER_ID, data.userId);
    localStorage.setItem(STORAGE_KEYS.BASE_URL, data.baseUrl);
    if (data.deviceId) {
      localStorage.setItem(STORAGE_KEYS.DEVICE_ID, data.deviceId);
    }
  },

  getAuth: () => {
    const accessToken = localStorage.getItem(STORAGE_KEYS.ACCESS_TOKEN);
    const userId = localStorage.getItem(STORAGE_KEYS.USER_ID);
    const baseUrl = localStorage.getItem(STORAGE_KEYS.BASE_URL);
    const deviceId = localStorage.getItem(STORAGE_KEYS.DEVICE_ID);

    if (!accessToken || !userId || !baseUrl) {
      return null;
    }

    return {
      accessToken,
      userId,
      baseUrl,
      deviceId: deviceId || undefined,
    };
  },

  clearAuth: () => {
    localStorage.removeItem(STORAGE_KEYS.ACCESS_TOKEN);
    localStorage.removeItem(STORAGE_KEYS.USER_ID);
    localStorage.removeItem(STORAGE_KEYS.BASE_URL);
    localStorage.removeItem(STORAGE_KEYS.DEVICE_ID);
  },

  // User preferences
  setSelectedRoom: (roomId: string | null) => {
    if (roomId) {
      localStorage.setItem(STORAGE_KEYS.SELECTED_ROOM_ID, roomId);
    } else {
      localStorage.removeItem(STORAGE_KEYS.SELECTED_ROOM_ID);
    }
  },

  getSelectedRoom: (): string | null => {
    return localStorage.getItem(STORAGE_KEYS.SELECTED_ROOM_ID);
  },

  setLastSyncTime: (timestamp: number) => {
    localStorage.setItem(STORAGE_KEYS.LAST_SYNC_TIME, timestamp.toString());
  },

  getLastSyncTime: (): number | null => {
    const time = localStorage.getItem(STORAGE_KEYS.LAST_SYNC_TIME);
    return time ? parseInt(time, 10) : null;
  },
};

// ==================== IndexedDB helpers ====================

const DB_NAME = 'river-chat-db';
const DB_VERSION = 1;

const STORES = {
  CONVERSATIONS: 'conversations',
  MESSAGES: 'messages',
} as const;

interface Conversation {
  roomId: string;
  name: string;
  lastEventTime: number;
  unreadCount: number;
  avatarUrl?: string;
  userId: string; // To scope conversations per user
}

interface StoredMessage {
  id: string;
  roomId: string;
  sender: string;
  content: string;
  timestamp: number;
  userId: string; // To scope messages per user
}

let dbInstance: IDBDatabase | null = null;

async function openDB(): Promise<IDBDatabase> {
  if (dbInstance) {
    return dbInstance;
  }

  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);

    request.onerror = () => {
      reject(new Error('Failed to open IndexedDB'));
    };

    request.onsuccess = () => {
      dbInstance = request.result;
      resolve(dbInstance);
    };

    request.onupgradeneeded = (event) => {
      const db = (event.target as IDBOpenDBRequest).result;

      // Create conversations store
      if (!db.objectStoreNames.contains(STORES.CONVERSATIONS)) {
        const conversationsStore = db.createObjectStore(STORES.CONVERSATIONS, {
          keyPath: 'roomId',
        });
        conversationsStore.createIndex('userId', 'userId', {
          unique: false,
        });
        conversationsStore.createIndex('lastEventTime', 'lastEventTime', {
          unique: false,
        });
      }

      // Create messages store
      if (!db.objectStoreNames.contains(STORES.MESSAGES)) {
        const messagesStore = db.createObjectStore(STORES.MESSAGES, {
          keyPath: 'id',
        });
        messagesStore.createIndex('userId', 'userId', {
          unique: false,
        });
        messagesStore.createIndex('roomId', 'roomId', {
          unique: false,
        });
        messagesStore.createIndex('timestamp', 'timestamp', {
          unique: false,
        });
        messagesStore.createIndex('roomUser', ['roomId', 'userId'], {
          unique: false,
        });
      }
    };
  });
}

export const indexedDBService = {
  // Conversations
  async saveConversations(
    conversations: Omit<Conversation, 'userId'>[],
    userId: string
  ): Promise<void> {
    if (typeof window === 'undefined') return;

    try {
      const db = await openDB();
      const transaction = db.transaction([STORES.CONVERSATIONS], 'readwrite');
      const store = transaction.objectStore(STORES.CONVERSATIONS);
      const userIdIndex = store.index('userId');

      // Clear existing conversations for this user
      return new Promise((resolve, reject) => {
        const clearRequest = userIdIndex.openCursor(IDBKeyRange.only(userId));

        clearRequest.onsuccess = (event) => {
          const cursor = (event.target as IDBRequest<IDBCursorWithValue>).result;
          if (cursor) {
            cursor.delete();
            cursor.continue();
          } else {
            // All cleared, now save new conversations
            conversations.forEach((conv) => {
              store.put({
                ...conv,
                userId,
              });
            });
            resolve();
          }
        };

        clearRequest.onerror = () => {
          reject(new Error('Failed to clear conversations'));
        };
      });
    } catch (error) {
      console.error('Failed to save conversations:', error);
    }
  },

  async getConversations(userId: string): Promise<Conversation[]> {
    if (typeof window === 'undefined') return [];

    try {
      const db = await openDB();
      const transaction = db.transaction([STORES.CONVERSATIONS], 'readonly');
      const store = transaction.objectStore(STORES.CONVERSATIONS);
      const userIdIndex = store.index('userId');

      return new Promise((resolve, reject) => {
        const request = userIdIndex.getAll(IDBKeyRange.only(userId));

        request.onsuccess = () => {
          const conversations = request.result as Conversation[];
          // Sort by lastEventTime descending
          conversations.sort((a, b) => b.lastEventTime - a.lastEventTime);
          resolve(conversations);
        };

        request.onerror = () => {
          reject(new Error('Failed to get conversations'));
        };
      });
    } catch (error) {
      console.error('Failed to get conversations:', error);
      return [];
    }
  },

  async updateConversation(
    conversation: Omit<Conversation, 'userId'>,
    userId: string
  ): Promise<void> {
    if (typeof window === 'undefined') return;

    try {
      const db = await openDB();
      const transaction = db.transaction([STORES.CONVERSATIONS], 'readwrite');
      const store = transaction.objectStore(STORES.CONVERSATIONS);

      return new Promise((resolve, reject) => {
        const request = store.put({
          ...conversation,
          userId,
        });

        request.onsuccess = () => resolve();
        request.onerror = () => reject(request.error);
      });
    } catch (error) {
      console.error('Failed to update conversation:', error);
    }
  },

  // Messages
  async saveMessages(
    messages: Omit<StoredMessage, 'userId' | 'roomId'>[],
    roomId: string,
    userId: string
  ): Promise<void> {
    if (typeof window === 'undefined') return;

    try {
      const db = await openDB();
      const transaction = db.transaction([STORES.MESSAGES], 'readwrite');
      const store = transaction.objectStore(STORES.MESSAGES);

      // Use Promise.all for parallel writes
      await Promise.all(
        messages.map(
          (msg) =>
            new Promise<void>((resolve, reject) => {
              const request = store.put({
                ...msg,
                roomId,
                userId,
              });

              request.onsuccess = () => resolve();
              request.onerror = () => reject(request.error);
            })
        )
      );
    } catch (error) {
      console.error('Failed to save messages:', error);
    }
  },

  async getMessages(roomId: string, userId: string): Promise<StoredMessage[]> {
    if (typeof window === 'undefined') return [];

    try {
      const db = await openDB();
      const transaction = db.transaction([STORES.MESSAGES], 'readonly');
      const store = transaction.objectStore(STORES.MESSAGES);
      const roomUserIndex = store.index('roomUser');

      return new Promise((resolve, reject) => {
        const request = roomUserIndex.getAll([roomId, userId]);

        request.onsuccess = () => {
          const messages = request.result as StoredMessage[];
          // Sort by timestamp ascending
          messages.sort((a, b) => a.timestamp - b.timestamp);
          resolve(messages);
        };

        request.onerror = () => {
          reject(new Error('Failed to get messages'));
        };
      });
    } catch (error) {
      console.error('Failed to get messages:', error);
      return [];
    }
  },

  async clearMessages(roomId: string, userId: string): Promise<void> {
    if (typeof window === 'undefined') return;

    try {
      const db = await openDB();
      const transaction = db.transaction([STORES.MESSAGES], 'readwrite');
      const store = transaction.objectStore(STORES.MESSAGES);
      const roomUserIndex = store.index('roomUser');

      return new Promise((resolve, reject) => {
        const request = roomUserIndex.openCursor(IDBKeyRange.only([roomId, userId]));

        request.onsuccess = (event) => {
          const cursor = (event.target as IDBRequest<IDBCursorWithValue>)
            .result;
          if (cursor) {
            cursor.delete();
            cursor.continue();
          } else {
            resolve();
          }
        };

        request.onerror = () => {
          reject(new Error('Failed to clear messages'));
        };
      });
    } catch (error) {
      console.error('Failed to clear messages:', error);
    }
  },

  async clearAllData(userId: string): Promise<void> {
    if (typeof window === 'undefined') return;

    try {
      const db = await openDB();
      
      // Clear conversations
      const conversationsTransaction = db.transaction(
        [STORES.CONVERSATIONS],
        'readwrite'
      );
      const conversationsStore = conversationsTransaction.objectStore(
        STORES.CONVERSATIONS
      );
      const conversationsUserIdIndex = conversationsStore.index('userId');
      
      await new Promise<void>((resolve, reject) => {
        const conversationsRequest = conversationsUserIdIndex.openCursor(
          IDBKeyRange.only(userId)
        );

        conversationsRequest.onsuccess = (event) => {
          const cursor = (event.target as IDBRequest<IDBCursorWithValue>).result;
          if (cursor) {
            cursor.delete();
            cursor.continue();
          } else {
            resolve();
          }
        };

        conversationsRequest.onerror = () => {
          reject(new Error('Failed to clear conversations'));
        };
      });

      // Clear messages
      const messagesTransaction = db.transaction(
        [STORES.MESSAGES],
        'readwrite'
      );
      const messagesStore = messagesTransaction.objectStore(STORES.MESSAGES);
      const messagesUserIdIndex = messagesStore.index('userId');
      
      await new Promise<void>((resolve, reject) => {
        const messagesRequest = messagesUserIdIndex.openCursor(
          IDBKeyRange.only(userId)
        );

        messagesRequest.onsuccess = (event) => {
          const cursor = (event.target as IDBRequest<IDBCursorWithValue>).result;
          if (cursor) {
            cursor.delete();
            cursor.continue();
          } else {
            resolve();
          }
        };

        messagesRequest.onerror = () => {
          reject(new Error('Failed to clear messages'));
        };
      });
    } catch (error) {
      console.error('Failed to clear all data:', error);
    }
  },
};

