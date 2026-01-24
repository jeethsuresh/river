// Use dynamic import to avoid SSR issues - types are imported separately
// to avoid webpack bundling issues
import type { MatrixClient as MC, MatrixEvent as ME, Room as R, IContent as IC } from 'matrix-js-sdk';

// Re-export types with aliases to avoid conflicts
export type MatrixClient = MC;
export type MatrixEvent = ME;
export type Room = R;
export type IContent = IC;

let matrixSDK: any = null;

async function getMatrixSDK() {
  if (typeof window === 'undefined') {
    throw new Error('matrix-js-sdk can only be used on the client side');
  }
  if (!matrixSDK) {
    matrixSDK = await import('matrix-js-sdk');
  }
  return matrixSDK;
}

export interface MatrixConfig {
  baseUrl: string;
  username: string;
  password: string;
}

export interface Conversation {
  roomId: string;
  name: string;
  lastEventTime: number;
  unreadCount: number;
  avatarUrl?: string;
}

export interface Message {
  id: string;
  sender: string;
  content: string;
  timestamp: number;
  event: MatrixEvent;
}

let client: MatrixClient | null = null;

export async function login(config: MatrixConfig): Promise<MatrixClient> {
  const sdk = await getMatrixSDK();
  const tempClient = sdk.createClient({
    baseUrl: config.baseUrl,
  });

  const { user_id, access_token, device_id } = await tempClient.login(
    'm.login.password',
    {
      user: config.username,
      password: config.password,
    }
  );

  client = sdk.createClient({
    baseUrl: config.baseUrl,
    accessToken: access_token,
    userId: user_id,
    deviceId: device_id,
  });

  return client;
}

export function getClient(): MatrixClient | null {
  return client;
}

export function setClient(newClient: MatrixClient | null) {
  client = newClient;
}

export async function createClientFromStorage(config: {
  baseUrl: string;
  accessToken: string;
  userId: string;
  deviceId?: string;
}): Promise<MatrixClient> {
  const sdk = await getMatrixSDK();
  return sdk.createClient({
    baseUrl: config.baseUrl,
    accessToken: config.accessToken,
    userId: config.userId,
    deviceId: config.deviceId,
  });
}

export function startSync(client: MatrixClient, onSync?: () => void): void {
  client.startClient({
    initialSyncLimit: 10,
  });

  // Handle sync state changes
  client.on('sync', (state: string, prevState: string | null) => {
    if (state === 'PREPARED' && onSync) {
      onSync();
    }
  });

  // Also handle when client is ready
  if (client.getSyncState() === 'PREPARED' && onSync) {
    onSync();
  }
}

export function getConversations(client: MatrixClient): Conversation[] {
  const rooms = client.getRooms();
  const userId = client.getUserId();
  
  return rooms
    .map((room: Room) => {
      const timeline = room.timeline;
      const lastEvent = timeline[timeline.length - 1];
      const lastEventTime = lastEvent?.getTs() || room.getLastLiveTimestamp() || 0;
      
      // Get room name - for DMs, show the other user's name
      let roomName = room.name;
      if (!roomName || roomName === 'Empty Room') {
        const members = room.getJoinedMembers();
        const otherMembers = members.filter(m => m.userId !== userId);
        if (otherMembers.length === 1) {
          roomName = otherMembers[0].name || otherMembers[0].userId;
        } else if (otherMembers.length > 1) {
          roomName = `${otherMembers.length} members`;
        } else {
          roomName = room.roomId;
        }
      }
      
      return {
        roomId: room.roomId,
        name: roomName,
        lastEventTime,
        unreadCount: room.getUnreadNotificationCount(),
        avatarUrl: room.getAvatarUrl(client.baseUrl, 64, 64, 'scale', false, true),
      };
    })
    .sort((a, b) => b.lastEventTime - a.lastEventTime);
}

export function getMessages(client: MatrixClient, roomId: string): Message[] {
  const room = client.getRoom(roomId);
  if (!room) return [];

  const timeline = room.timeline;
  
  return timeline
    .filter((event: MatrixEvent) => {
      return event.getType() === 'm.room.message' && 
             event.getContent().msgtype === 'm.text';
    })
    .map((event: MatrixEvent) => {
      const content = event.getContent();
      return {
        id: event.getId() || '',
        sender: event.getSender() || 'Unknown',
        content: content.body || '',
        timestamp: event.getTs(),
        event,
      };
    })
    .sort((a, b) => a.timestamp - b.timestamp);
}

export function sendMessage(
  client: MatrixClient,
  roomId: string,
  message: string
): Promise<string> {
  const content: IContent = {
    msgtype: 'm.text',
    body: message,
  };

  return client.sendEvent(roomId, 'm.room.message', content);
}

export async function loadOlderMessages(
  client: MatrixClient,
  roomId: string,
  limit: number = 30
): Promise<boolean> {
  const room = client.getRoom(roomId);
  if (!room) return false;

  const timeline = room.getLiveTimeline();
  const paginationToken = timeline.getPaginationToken('b');
  
  // If no pagination token, there are no more messages
  if (!paginationToken) return false;

  try {
    const result = await client.paginateEventTimeline(timeline, {
      backwards: true,
      limit,
    });
    return result;
  } catch (error) {
    console.error('Failed to load older messages:', error);
    return false;
  }
}

export function hasMoreMessages(client: MatrixClient, roomId: string): boolean {
  const room = client.getRoom(roomId);
  if (!room) return false;

  const timeline = room.getLiveTimeline();
  return timeline.getPaginationToken('b') !== null;
}

export function getRoomName(client: MatrixClient, roomId: string): string {
  const room = client.getRoom(roomId);
  if (!room) return roomId;
  
  const userId = client.getUserId();
  let roomName = room.name;
  
  if (!roomName || roomName === 'Empty Room') {
    const members = room.getJoinedMembers();
    const otherMembers = members.filter(m => m.userId !== userId);
    if (otherMembers.length === 1) {
      roomName = otherMembers[0].name || otherMembers[0].userId;
    } else if (otherMembers.length > 1) {
      roomName = `${otherMembers.length} members`;
    } else {
      roomName = roomId;
    }
  }
  
  return roomName;
}

