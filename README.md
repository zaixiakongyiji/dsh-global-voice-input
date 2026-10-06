# DSH Global Voice Input

Windows-only DSH Bundle. Press `Ctrl+Alt+Space` from any foreground application to restore DSH, record from the default microphone, stop after silence, reuse the currently active Session, transcribe with the installed Voice Input Bundle, and submit the text automatically.

The `0.2.0` UI adds a compact status pill in the composer. Its buttons use icons only: the left button opens direct text input, the middle icon changes with the recording state, and the right button expands a live preview of the current Session reply. On Windows, the same controls are also shown in a small always-on-top desktop overlay, so the status remains visible when DSH is unfocused or minimized. Drag an empty area of the capsule to move it; its position is kept while the overlay resizes for input or reply preview.

The plugin settings expose the shortcut, silence timeout, maximum recording duration, automatic submission, desktop overlay visibility, and reply preview visibility. The shortcut is captured by clicking its button and pressing a modifier-plus-key combination; `Esc` cancels that capture. The in-app icon bar is kept hidden while its background binding continues to track the active Session. Changes to the shortcut take effect after DSH reloads.

Defaults are `Ctrl+Alt+Space`, `1200 ms` silence, `60 s` maximum duration, automatic submission enabled, and the desktop overlay enabled.

The plugin never creates a Session. If the current Session is unavailable, locked, or its draft changed while recording, the result stays local and a status message is shown. The Host event is deliberately named `trigger`; a future wake-word implementation can publish the same event without changing the Client.

## Test

运行 `npm test` 可验证 DSH Gateway → Host → Windows 悬浮窗的状态传输，覆盖录音波形、音量变化、转写、停止、中文回复和过期状态。测试使用旁边的 `../dsh-sdk/dsh/node_modules`；其他目录可通过 `DSH_TEST_NODE_MODULES` 指定 DSH 的依赖目录。测试会短暂打开独立悬浮窗，不请求麦克风、不注册快捷键、不发送会话消息。

状态接口使用 DSH 的 SRC Remote 解析，方法参数必须是普通参数名。不要把 `reportState(state)` 改成带默认值的签名；这会触发 `gateway/signature-invalid`，使图标、音量和回复都无法同步。Client 必须检查 Remote 返回的 `ok` 字段，不能只通过 `.catch()` 判断失败。

1. Open DSH with the Global Voice Input bundle enabled and open an existing Session.
2. In the Voice Input settings, make sure the SenseVoice provider is prepared. Allow microphone access when the browser asks.
3. Press `Ctrl+Alt+Space` once while DSH is focused, unfocused, or minimized. DSH should come to the foreground and show the recording status. Keep speaking after the status changes to `正在录音`; do not hold the shortcut as a push-to-talk key.
4. Speak a short sentence, then stop speaking. After about 1.2 seconds of silence the recording ends, the text is transcribed, inserted into that same Session, and submitted automatically.
5. Repeat while the Session is generating. The draft should be submitted through the Session's normal queue; no new Session is created.
6. The desktop capsule stays above other windows. Its middle icon is red while recording, the left icon opens a text field, and the right icon expands the current reply preview.

If nothing happens, check that DSH is running, the bundle is enabled, and the shortcut is not already registered by another application. The first status message is shown in the composer; a shortcut conflict is reported by the Host helper.

After updating the bundle, exit DSH from the tray menu and confirm that `DeepSeek Harness.exe` has exited before launching it again. The browser-side bundle is loaded once per DSH process, so closing only the main window can leave the previous UI in memory. The desktop capsule is placed at the lower-right of the primary monitor; its visibility is controlled by `显示桌面置顶悬浮窗` in the plugin page.
