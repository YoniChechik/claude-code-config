"use client";

import "../styles/globals.css";
import ErrorBoundary from "@/components/ErrorBoundary";
import GlobalErrorHandler from "@/components/GlobalErrorHandler";
import StatusBar from "@/components/StatusBar";
import Head from "next/head";

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en" className="dark">
      <Head>
        <title>ccweb - Claude Code Web UI</title>
        <meta name="description" content="Multi-session Claude Code interface" />
        <link rel="icon" href="/favicon.ico" sizes="32x32" />
        <link rel="icon" href="/favicon.svg" type="image/svg+xml" />
        <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
      </Head>
      <body className="bg-surface-primary text-text-primary">
        <StatusBar />
        <ErrorBoundary>
          <GlobalErrorHandler />
          {children}
        </ErrorBoundary>
      </body>
    </html>
  );
}
