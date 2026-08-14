import React from 'react';
import { ActivityIndicator, LogBox, StatusBar, Text, View } from 'react-native';

LogBox.ignoreLogs(['Attempted to import the module']);
import { NavigationContainer } from '@react-navigation/native';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import type { MainTabParamList, RootStackParamList } from './src/navigation/types';
import { ChatsScreen } from './src/screens/ChatsScreen';
import { DocScreen } from './src/screens/DocScreen';
import { DocsScreen } from './src/screens/DocsScreen';
import { LoginScreen } from './src/screens/LoginScreen';
import { RecentScreen } from './src/screens/RecentScreen';
import { SettingsScreen } from './src/screens/SettingsScreen';
import { TopicScreen } from './src/screens/TopicScreen';
import { SessionProvider, useSession } from './src/session/Session';
import { ThemeProvider, useTheme } from './src/theme/Theme';

const Stack = createNativeStackNavigator<RootStackParamList>();
const Tabs = createBottomTabNavigator<MainTabParamList>();

function MainTabs() {
  const { colors } = useTheme();
  return (
    <Tabs.Navigator
      screenOptions={{
        headerShown: false,
        tabBarStyle: {
          backgroundColor: colors.topBarBg,
          borderTopColor: colors.topBarBorder,
          borderTopWidth: 1,
          height: 72,
          paddingTop: 6,
          paddingBottom: 10,
        },
        tabBarActiveTintColor: colors.accent,
        tabBarInactiveTintColor: colors.mutedFg,
        tabBarLabelStyle: { fontSize: 12, fontWeight: '700' },
      }}>
      <Tabs.Screen
        name="Recent"
        component={RecentScreen}
        options={{
          tabBarLabel: 'Recent',
          tabBarIcon: ({ color }) => <Text style={{ color, fontSize: 16 }}>●</Text>,
        }}
      />
      <Tabs.Screen
        name="Chats"
        component={ChatsScreen}
        options={{
          tabBarLabel: 'Chats',
          tabBarIcon: ({ color }) => <Text style={{ color, fontSize: 16 }}>☰</Text>,
        }}
      />
      <Tabs.Screen
        name="Docs"
        component={DocsScreen}
        options={{
          tabBarLabel: 'Docs',
          tabBarIcon: ({ color }) => <Text style={{ color, fontSize: 16 }}>¶</Text>,
        }}
      />
      <Tabs.Screen
        name="Settings"
        component={SettingsScreen}
        options={{
          tabBarLabel: 'Settings',
          tabBarIcon: ({ color }) => <Text style={{ color, fontSize: 16 }}>⚙</Text>,
        }}
      />
    </Tabs.Navigator>
  );
}

function Root() {
  const { session, ready } = useSession();
  const { colors, mode } = useTheme();

  if (!ready) {
    return (
      <View style={{ flex: 1, backgroundColor: colors.bg, justifyContent: 'center' }}>
        <ActivityIndicator color={colors.accent} />
      </View>
    );
  }

  return (
    <>
      <StatusBar barStyle={mode === 'dark' ? 'light-content' : 'dark-content'} />
      <NavigationContainer>
        <Stack.Navigator
          screenOptions={{
            headerStyle: { backgroundColor: colors.topBarBg },
            headerTintColor: colors.fg,
            headerShadowVisible: false,
            contentStyle: { backgroundColor: colors.bg },
          }}>
          {session ? (
            <>
              <Stack.Screen
                name="Main"
                component={MainTabs}
                options={{ headerShown: false }}
              />
              <Stack.Screen name="Topic" component={TopicScreen} />
              <Stack.Screen name="Doc" component={DocScreen} />
            </>
          ) : (
            <Stack.Screen
              name="Login"
              component={LoginScreen}
              options={{ headerShown: false }}
            />
          )}
        </Stack.Navigator>
      </NavigationContainer>
    </>
  );
}

export default function App() {
  return (
    <SafeAreaProvider>
      <ThemeProvider>
        <SessionProvider>
          <Root />
        </SessionProvider>
      </ThemeProvider>
    </SafeAreaProvider>
  );
}
