export type RootStackParamList = {
  Login: undefined;
  Main: undefined;
  Topic: { convBase: string; sid: string; title: string; focusId?: string };
  Sessions: { convUrl: string; title: string };
  Doc: { slug: string; title: string };
};

export type MainTabParamList = {
  Recent: undefined;
  Chats: undefined;
  Docs: undefined;
  Settings: undefined;
};
