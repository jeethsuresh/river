import type { Metadata } from 'next'
import './globals.css'

export const metadata: Metadata = {
  title: 'River Chat - Matrix Client',
  description: 'A Next.js Matrix client',
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  )
}

