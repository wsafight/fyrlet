export interface AppContract {
  operations: {
    "inbox.add": { input: { "content_type"?: "text" | "link" | "code"; "text": string }; output: { "archived": boolean; "content_type": "text" | "link" | "code"; "id": string; "inserted_at": string; "text": string; "updated_at": string; "version": number } };
    "inbox.archive": { input: { "archived"?: boolean; "expected_version": number; "id": string }; output: { "archived": boolean; "content_type": "text" | "link" | "code"; "id": string; "inserted_at": string; "text": string; "updated_at": string; "version": number } };
    "inbox.delete": { input: { "expected_version": number; "id": string }; output: { "deleted": boolean; "id": string } };
    "inbox.history": { input: { "cursor"?: string; "include_archived"?: boolean; "limit"?: number }; output: { "items": Array<{ "archived": boolean; "content_type": "text" | "link" | "code"; "id": string; "inserted_at": string; "text": string; "updated_at": string; "version": number }>; "next_cursor": string | null } };
    "inbox.update": { input: { "expected_version": number; "id": string; "text": string }; output: { "archived": boolean; "content_type": "text" | "link" | "code"; "id": string; "inserted_at": string; "text": string; "updated_at": string; "version": number } };
  };
  subscriptions: {
    "inbox.recent": { input: { "include_archived"?: boolean; "limit"?: number }; output: Array<{ "archived": boolean; "content_type": "text" | "link" | "code"; "id": string; "inserted_at": string; "text": string; "updated_at": string; "version": number }> };
  };
}
