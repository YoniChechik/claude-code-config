"use client";

import "../styles/globals.css";
import ErrorBoundary from "@/components/ErrorBoundary";
import GlobalErrorHandler from "@/components/GlobalErrorHandler";
import VersionBar from "@/components/VersionBar";
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
      </Head>
      <body className="bg-gray-900 text-gray-100">
        <VersionBar />
        <ErrorBoundary>
          <GlobalErrorHandler />
          {children}
        </ErrorBoundary>
      </body>
    </html>
  );
}
