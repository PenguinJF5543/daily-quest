import type { Metadata } from "next";
import "./globals.css";
import { SerwistProvider } from "@serwist/next/react";

export const metadata: Metadata = {
  title: "Daily Quest",
  manifest: "/manifest.json",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="es">
      <body>
        <SerwistProvider swUrl="/sw.js">
          {children}
        </SerwistProvider>
      </body>
    </html>
  );
}
