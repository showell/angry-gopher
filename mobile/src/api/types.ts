export type Conversation = {
  conv: string;
  partner: { id: string; name: string };
  default: string;
  sessions: string[];
};

export type ConversationsResponse = {
  me: string;
  conversations: Conversation[];
};

export type RecentChatEvent = {
  kind: 'chat';
  at: string;
  url: string;
  who?: string;
  where?: string;
  topic?: string;
  excerpt?: string;
  dm?: boolean;
};

export type RecentDocEvent = {
  kind: 'doc';
  at: string;
  who?: string;
  slug: string;
  title?: string;
};

export type RecentEvent = RecentChatEvent | RecentDocEvent;

export type WireMessage = {
  index: number;
  from: string;
  at: string;
  html: string;
  markdown: string;
  id: string;
  mine: boolean;
  cid?: string;
};

export type TopicRef = {
  convBase: string;
  sid: string;
  msgId?: string;
};

export type UploadResult = {
  url: string;
  name: string;
  kind: 'image' | 'video';
  width: number;
  height: number;
};
