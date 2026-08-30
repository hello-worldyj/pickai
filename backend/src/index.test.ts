import { describe, expect, it } from "vitest";
import { base64ToBytes, isMessage, isQueryRequest, toChatContent } from "./index";

describe("isMessage", () => {
  it("accepts a message with text", () => {
    expect(isMessage({ role: "user", text: "hi" })).toBe(true);
  });

  it("accepts a message with an image", () => {
    expect(isMessage({ role: "user", imageBase64: "aGk=" })).toBe(true);
  });

  it("rejects a message with neither text nor image", () => {
    expect(isMessage({ role: "user" })).toBe(false);
  });

  it("rejects an invalid role", () => {
    expect(isMessage({ role: "system", text: "hi" })).toBe(false);
  });

  it("rejects empty text", () => {
    expect(isMessage({ role: "user", text: "" })).toBe(false);
  });

  it("rejects non-objects", () => {
    expect(isMessage("hi")).toBe(false);
    expect(isMessage(null)).toBe(false);
    expect(isMessage(undefined)).toBe(false);
  });
});

describe("isQueryRequest", () => {
  it("accepts a valid answer request", () => {
    expect(isQueryRequest({ mode: "answer", messages: [{ role: "user", text: "hi" }] })).toBe(true);
  });

  it("rejects an invalid mode", () => {
    expect(isQueryRequest({ mode: "summarize", messages: [{ role: "user", text: "hi" }] })).toBe(false);
  });

  it("rejects an empty messages array", () => {
    expect(isQueryRequest({ mode: "answer", messages: [] })).toBe(false);
  });

  it("rejects more than 20 messages", () => {
    const messages = Array.from({ length: 21 }, () => ({ role: "user", text: "hi" }));
    expect(isQueryRequest({ mode: "answer", messages })).toBe(false);
  });

  it("rejects if any message is invalid", () => {
    expect(
      isQueryRequest({ mode: "answer", messages: [{ role: "user", text: "hi" }, { role: "user" }] })
    ).toBe(false);
  });
});

describe("base64ToBytes", () => {
  it("decodes correctly", () => {
    // "hi" base64-encoded
    const bytes = base64ToBytes("aGk=");
    expect(Array.from(bytes)).toEqual([104, 105]);
  });

  it("round-trips arbitrary binary data, including a size like a real screenshot", () => {
    const original = new Uint8Array(500_000);
    for (let i = 0; i < original.length; i++) original[i] = i % 256;
    const b64 = btoa(String.fromCharCode(...original.subarray(0, 60000))); // chunk to avoid call-stack limits
    const decoded = base64ToBytes(b64);
    expect(decoded.length).toBe(60000);
    expect(Array.from(decoded)).toEqual(Array.from(original.subarray(0, 60000)));
  });

  it("handles an empty string", () => {
    expect(base64ToBytes("").length).toBe(0);
  });
});

describe("toChatContent", () => {
  it("returns plain text for a text-only message", () => {
    expect(toChatContent({ role: "user", text: "hello" })).toBe("hello");
  });

  it("truncates text over MAX_TEXT_LENGTH", () => {
    const longText = "a".repeat(9000);
    const result = toChatContent({ role: "user", text: longText });
    expect(typeof result).toBe("string");
    expect((result as string).length).toBe(8000);
  });

  it("returns multimodal content for an image message", () => {
    const result = toChatContent({ role: "user", imageBase64: "aGk=", text: "what is this" });
    expect(Array.isArray(result)).toBe(true);
    const arr = result as { type: string }[];
    expect(arr[0].type).toBe("text");
    expect(arr[1].type).toBe("image_url");
  });

  it("uses the default image instruction when no text is given", () => {
    const result = toChatContent({ role: "user", imageBase64: "aGk=" }) as { type: string; text?: string }[];
    expect(result[0].text).toMatch(/identify the question/i);
  });
});
