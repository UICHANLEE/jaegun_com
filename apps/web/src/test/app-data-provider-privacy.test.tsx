import { act, fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { AppDataProvider, useAppData } from "../data/AppDataProvider";
import { createDemoState } from "../data/seed";

const DEMO_STORAGE_KEY = "jaegun-community-demo-v4";

function ProviderProbe() {
  const data = useAppData();
  return (
    <>
      <button type="button" onClick={() => data.enterDemo("executive", ["treasurer"])}>fresh demo</button>
      <button type="button" onClick={() => void data.signOut()}>sign out</button>
      <output data-testid="provider-state">
        {JSON.stringify({
          viewerId: data.viewer?.profile.id ?? null,
          viewerOffices: data.viewer?.membership?.executiveOfficeCodes ?? [],
          organizationIds: data.organizations.map((item) => item.id),
          postIds: data.posts.map((item) => item.id),
          applicationIds: data.applications.map((item) => item.id),
          memberIds: data.members.map((item) => item.membershipId),
          conversationIds: data.conversations.map((item) => item.id),
          messageConversationIds: Object.keys(data.messagesByConversation),
          notificationIds: data.notifications.map((item) => item.id),
          minuteIds: data.meetingMinutes.map((item) => item.id),
          ledgerIds: data.ledgerEntries.map((item) => item.id),
        })}
      </output>
    </>
  );
}

function providerSnapshot() {
  return JSON.parse(screen.getByTestId("provider-state").textContent ?? "{}") as Record<string, unknown>;
}

describe("AppDataProvider private-state boundaries", () => {
  it("enters every demo persona from a fresh seed instead of retaining persisted private state", () => {
    const contaminated = createDemoState();
    window.localStorage.setItem(DEMO_STORAGE_KEY, JSON.stringify({
      ...contaminated,
      posts: [{ ...contaminated.posts[0], id: "private-remote-post", title: "다른 사용자의 비공개 글" }],
      applications: [{ ...contaminated.applications[0], id: "private-remote-application" }],
      conversations: [{ ...contaminated.conversations[0], id: "private-remote-conversation" }],
      messagesByConversation: {
        "private-remote-conversation": [{
          id: "private-remote-message",
          conversationId: "private-remote-conversation",
          senderId: "other-user",
          body: "private",
          createdAt: new Date().toISOString(),
          status: "sent",
          media: [],
        }],
      },
      notifications: [{ ...contaminated.notifications[0], id: "private-remote-notification" }],
      meetingMinutes: [{ ...contaminated.meetingMinutes[0], id: "private-remote-minute" }],
      ledgerEntries: [{ ...contaminated.ledgerEntries[0], id: "private-remote-ledger" }],
    }));

    render(<AppDataProvider><ProviderProbe /></AppDataProvider>);
    expect(JSON.stringify(providerSnapshot())).toContain("private-remote-post");

    fireEvent.click(screen.getByRole("button", { name: "fresh demo" }));
    const fresh = providerSnapshot();
    expect(JSON.stringify(fresh)).not.toContain("private-remote");
    expect(fresh.viewerId).toBe("demo-executive");
    expect(fresh.viewerOffices).toEqual(["treasurer"]);
    expect(fresh.postIds).toContain("post-retreat");
  });

  it("clears every private collection while retaining the public signup directory on sign out", async () => {
    render(<AppDataProvider><ProviderProbe /></AppDataProvider>);
    fireEvent.click(screen.getByRole("button", { name: "fresh demo" }));
    expect(providerSnapshot().viewerId).toBe("demo-executive");
    const publicOrganizationIds = providerSnapshot().organizationIds;

    await act(async () => {
      fireEvent.click(screen.getByRole("button", { name: "sign out" }));
    });

    const signedOut = providerSnapshot();
    expect(signedOut.viewerId).toBeNull();
    expect(signedOut.organizationIds).toEqual(publicOrganizationIds);
    for (const key of [
      "postIds",
      "applicationIds",
      "memberIds",
      "conversationIds",
      "messageConversationIds",
      "notificationIds",
      "minuteIds",
      "ledgerIds",
    ]) {
      expect(signedOut[key]).toEqual([]);
    }
  });
});
