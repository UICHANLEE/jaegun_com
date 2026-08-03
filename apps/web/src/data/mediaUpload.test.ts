import { describe, expect, it } from "vitest";
import { validateMediaFile } from "./mediaUpload";

function fileOfSize(name: string, type: string, byteSize: number) {
  const file = new File([new Uint8Array(1)], name, { type });
  Object.defineProperty(file, "size", { value: byteSize });
  return file;
}

describe("media upload validation", () => {
  it("accepts supported photos and videos within service limits", () => {
    expect(validateMediaFile(fileOfSize("photo.jpg", "image/jpeg", 15 * 1024 * 1024))).toBeNull();
    expect(validateMediaFile(fileOfSize("video.mp4", "video/mp4", 500 * 1024 * 1024))).toBeNull();
  });

  it("rejects oversized and unsupported files with actionable messages", () => {
    expect(validateMediaFile(fileOfSize("photo.png", "image/png", 15 * 1024 * 1024 + 1))).toContain("15MB");
    expect(validateMediaFile(fileOfSize("video.mov", "video/quicktime", 500 * 1024 * 1024 + 1))).toContain("500MB");
    expect(validateMediaFile(fileOfSize("document.pdf", "application/pdf", 100))).toContain("사진 또는 영상");
  });
});
