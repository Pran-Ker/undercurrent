# mobile-app

Not scaffolded yet. The spec is [`../MOBILE_APP.md`](../MOBILE_APP.md); the API it talks to is
[`../backend/API.md`](../backend/API.md).

Suggested start:

```sh
npx create-expo-app@latest . --template blank-typescript
npx expo install @elevenlabs/react-native @livekit/react-native @livekit/react-native-webrtc @config-plugins/react-native-webrtc @livekit/react-native-expo-plugin livekit-client
```

Then follow ElevenLabs' Expo guide for `app.json` (scheme, microphone permission, the two plugins)
and `npx expo prebuild --clean`. Run the backend first (`cd ../backend && go run ./cmd/undercurrent serve`)
and point `EXPO_PUBLIC_BACKEND_URL` at it.
