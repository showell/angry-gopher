import React from 'react';
import { ActivityIndicator, StatusBar, View } from 'react-native';
import { NavigationContainer } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import type { RootStackParamList } from './src/navigation/types';
import { LoginScreen } from './src/screens/LoginScreen';
import { RecentScreen } from './src/screens/RecentScreen';
import { SettingsScreen } from './src/screens/SettingsScreen';
import { TopicScreen } from './src/screens/TopicScreen';
import { SessionProvider, useSession } from './src/session/Session';
import { ThemeProvider, useTheme } from './src/theme/Theme';

const Stack = createNativeStackNavigator<RootStackParamList>();

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
                name="Recent"
                component={RecentScreen}
                options={{ headerShown: false }}
              />
              <Stack.Screen name="Topic" component={TopicScreen} />
              <Stack.Screen name="Settings" component={SettingsScreen} />
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
