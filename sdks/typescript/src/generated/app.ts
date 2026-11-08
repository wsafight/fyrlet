export interface AppContract {
  operations: {
    "inbox.add": { kind: "write"; input: { "content_type"?: "text" | "link" | "code"; "text": string }; output: { "archived": boolean; "content_type": "text" | "link" | "code"; "id": string; "inserted_at": string; "text": string; "updated_at": string; "version": number } };
    "inbox.archive": { kind: "write"; input: { "archived"?: boolean; "expected_version": number; "id": string }; output: { "archived": boolean; "content_type": "text" | "link" | "code"; "id": string; "inserted_at": string; "text": string; "updated_at": string; "version": number } };
    "inbox.delete": { kind: "write"; input: { "expected_version": number; "id": string }; output: { "deleted": boolean; "id": string } };
    "inbox.history": { kind: "read"; input: { "cursor"?: string; "include_archived"?: boolean; "limit"?: number }; output: { "items": Array<{ "archived": boolean; "content_type": "text" | "link" | "code"; "id": string; "inserted_at": string; "text": string; "updated_at": string; "version": number }>; "next_cursor": string | null } };
    "inbox.update": { kind: "write"; input: { "expected_version": number; "id": string; "text": string }; output: { "archived": boolean; "content_type": "text" | "link" | "code"; "id": string; "inserted_at": string; "text": string; "updated_at": string; "version": number } };
  };
  subscriptions: {
    "inbox.recent": { input: { "include_archived"?: boolean; "limit"?: number }; output: Array<{ "archived": boolean; "content_type": "text" | "link" | "code"; "id": string; "inserted_at": string; "text": string; "updated_at": string; "version": number }> };
  };
  presence: {

  };
}

export const operationMetadata = {
  "inbox.add": {
    "kind": "write"
  },
  "inbox.archive": {
    "kind": "write"
  },
  "inbox.delete": {
    "kind": "write"
  },
  "inbox.history": {
    "kind": "read"
  },
  "inbox.update": {
    "kind": "write"
  }
} as const;
