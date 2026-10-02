"use client";
import { createClient } from "@/lib/supabase/client";
import { useRouter } from "next/navigation";
export default function LogoutButton(){const router=useRouter();async function logout(){await createClient().auth.signOut();router.push("/");router.refresh();}return <button className="btn secondary" onClick={logout}>Keluar</button>;}