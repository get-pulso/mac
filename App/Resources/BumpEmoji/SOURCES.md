# Telegram animation artwork for Bump reactions and new friends

Source: https://github.com/saeedtahmtan/telemoji
Revision: 4f45fca016c71de9d2a9e15c07ae1fe3d8327a28
Retrieved: 2026-09-16; handshake 2026-09-17 from the same revision

Original Telegram TGS vectors are preserved in Sources/. Each is rendered at 60 frames per second, 192 × 192, with 16/17 ms WebP frame delays (exactly 60 frames per second averaged over each second). No interpolation of low-fps raster images. ImageIO decodes at 160 px for the 350 pt popover. Only the current effect's two animations are retained.

| Local file | Upstream TGS | Frames |
| --- | --- | --- |
| thumb | tgs/animated/U+1F44D_1.tgs | 116 |
| clap | tgs/animated/U+1F44F_1.tgs | 130 |
| muscle | tgs/animated/U+1F4AA_1.tgs | 180 |
| fire | tgs/animated/U+1F525_1.tgs | 180 |
| seedling | tgs/animated/U+1F331_1.tgs | 120 |
| star | tgs/animated/U+1F31F_1.tgs | 180 |
| herb | tgs/animated/U+1F33F_1.tgs | 180 |
| handshake | tgs/animated/U+1F91D_1.tgs | 180 |

The handshake belongs to no bump effect: the notch island plays it for a friend request answered and for a new friend, and decodes it on its own. It is the one clip absent from `BumpEmojiLibrary.names`, which the popover's fan draws from.

Renderer: @lottiefiles/dotlottie-web 0.80.0, @napi-rs/canvas, sharp; offline asset preparation only. No new runtime dependency.

Telegram retains rights to its original artwork. A public source repository does not establish permission for commercial redistribution. These resources are included with the native Bump integration requested for the local app. Commercial redistribution rights have not been independently established; no release or distribution was performed. The earlier personal-use-only mirror assets were replaced; its license notice is retained as historical provenance in License.txt, not as a license grant for this source.

Primary animation format reference: https://core.telegram.org/api/stickers
Native client reference, no code copied: https://github.com/overtake/TelegramSwift/blob/master/Telegram-Mac/EmojiAnimationEffectView.swift

The original multicolor thumb reaction was also inspected from https://github.com/ilyhalight/telegram-emoji-effects (tgs/U+1F44D/0.tgs). Firstlight's current fan uses its own trajectories and the individual Telegram emoji listed above. No Telegram account credentials or personal messages are accessed.

Reproduce one asset (Bun is needed for local file:// WASM loading):

```sh
npm install --prefix /tmp/firstlight-vector-render --no-audit --no-fund @lottiefiles/dotlottie-web@0.80.0 @napi-rs/canvas sharp
bun Design/bump-effects/render-emoji.mjs App/Resources/BumpEmoji/Sources/clap.tgs /tmp/clap-60.webp
```

The renderer script itself lives in Design/bump-effects, outside the app bundle. The runtime resources are included by the BumpEmoji folder resource.
