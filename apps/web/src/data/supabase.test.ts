import { describe, expect, it } from "vitest";
import { normalizeSupabaseUrl } from "./supabase";

describe("Supabase configuration validation", () => {
  it("accepts secure hosted URLs and local development endpoints", () => {
    expect(normalizeSupabaseUrl(" https://project.supabase.co/ ")).toBe("https://project.supabase.co");
    expect(normalizeSupabaseUrl("http://127.0.0.1:54321")).toBe("http://127.0.0.1:54321");
  });

  it("fails closed for malformed, credential-bearing, or insecure remote URLs", () => {
    expect(normalizeSupabaseUrl(undefined)).toBeNull();
    expect(normalizeSupabaseUrl("foo")).toBeNull();
    expect(normalizeSupabaseUrl("https://user:secret@example.com")).toBeNull();
    expect(normalizeSupabaseUrl("http://example.com")).toBeNull();
  });
});
