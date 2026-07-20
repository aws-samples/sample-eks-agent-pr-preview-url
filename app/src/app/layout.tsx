// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT-0
import type { ReactNode } from 'react';

export const metadata = {
  title: 'pr-preview · reference workload',
  description: 'Next.js reference workload for the EKS PR preview platform',
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body
        style={{
          margin: 0,
          fontFamily:
            'ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
          background: '#0f1115',
          color: '#e7e9ee',
        }}
      >
        {children}
      </body>
    </html>
  );
}