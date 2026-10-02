import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
export async function getCurrentProfile(){const supabase=await createClient();const {data,error}=await supabase.auth.getClaims();const userId=data?.claims?.sub;if(error||!userId)return null;const {data:profile}=await supabase.from("profiles").select("*").eq("id",userId).maybeSingle();return profile;}
export async function requireMember(){const profile=await getCurrentProfile();if(!profile)redirect("/login");if(profile.status!=="active")redirect("/login?error=suspended");return profile;}
export async function requireAdmin(){const profile=await requireMember();if(profile.role!=="admin")redirect("/dashboard");return profile;}