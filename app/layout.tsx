import "./globals.css";
import type { Metadata } from "next";
export const metadata:Metadata={title:"ProjectBumn — Reseller Platform",description:"Platform reseller dengan referral, order, komisi dan saldo."};
export default function RootLayout({children}:{children:React.ReactNode}){return <html lang="id"><body>{children}</body></html>;}