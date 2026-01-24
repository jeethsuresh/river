# River Chat - Matrix Client

A modern Next.js Matrix client with a responsive master-detail interface.

## Features

- 🔐 Login with username and password to any Matrix server
- 💬 Real-time message syncing
- 📱 Responsive design (mobile and desktop)
- 🗂️ Master-detail view with conversation list
- 📅 Messages sorted chronologically (newest at bottom)
- 🔄 Conversations sorted reverse-chronologically (newest at top)

## Getting Started

### Installation

```bash
npm install
```

### Development

```bash
npm run dev
```

Open [http://localhost:3000](http://localhost:3000) in your browser.

### Login

1. Enter your Matrix server URL (e.g., `https://matrix.org`)
2. Enter your username (e.g., `@username:matrix.org`)
3. Enter your password
4. Click "Login"

The app will automatically sync with the server and display your conversations.

## Usage

- **Desktop**: The conversation list is always visible on the left, with the chat view on the right
- **Mobile**: Tap a conversation to view it, use the "Back" button to return to the list
- **Sending Messages**: Type in the input at the bottom and press Enter or click Send
- **Logout**: Click the "Logout" button in the header

## Project Structure

- `app/` - Next.js app directory
  - `page.tsx` - Login page
  - `chat/page.tsx` - Main chat interface
- `components/` - React components
  - `LoginPage.tsx` - Login form
  - `ChatInterface.tsx` - Main chat layout
  - `ConversationList.tsx` - List of conversations
  - `ChatView.tsx` - Individual conversation view
- `lib/matrixClient.ts` - Matrix SDK wrapper and utilities

## Technologies

- Next.js 14
- React 18
- TypeScript
- Matrix JS SDK
- CSS Modules

