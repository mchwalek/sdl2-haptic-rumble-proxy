# SDL2 haptic rumble proxy

A drop-in `SDL2.dll` for Windows that brings back controller rumble in older SDL2
games when you play with a DualShock 4, DualSense, Switch Pro or similar pad.

## The problem

Many SDL2 games use the old haptic API for rumble (`SDL_HapticOpenFromJoystick`
and `SDL_HapticRumblePlay`). On Windows that API only reaches DirectInput
force-feedback and XInput devices. Current SDL2 versions drive PlayStation and
Nintendo pads through HIDAPI, which the haptic API cannot reach. Rumble for
those pads only works through `SDL_JoystickRumble` (added in SDL 2.0.9), and
these games never call it. Upgrading `SDL2.dll` alone does not help.

The usual workaround, Steam Input, converts the pad to an Xbox controller. The
game then shows Xbox button prompts.

## What the proxy does

The proxy takes the place of `SDL2.dll` and forwards every function to the real
SDL2, which is renamed to `_SDL2_real.dll`. It replaces only the `SDL_Haptic*`
functions:

- When the game opens a haptic device for a joystick that supports
  `SDL_JoystickRumble`, the proxy returns its own handle. `SDL_HapticRumblePlay`
  on that handle calls `SDL_JoystickRumble` with the same strength on both motors.
- Joysticks without rumble support get the real `SDL_HapticOpenFromJoystick`.
- Other haptic functions called with a proxy handle fail cleanly. A proxy handle
  supports simple rumble only.

The pad is still a native pad, so the game keeps its PlayStation or Nintendo
button prompts.

## Does it apply to my game?

Run the detector on the game folder:

```powershell
.\check.ps1 '<game_dir>'
```

| Verdict | Meaning |
|---|---|
| **PROXY APPLIES** | The game rumbles through `SDL_HapticRumblePlay`. Use the proxy. |
| **UPGRADE SDL2** | The game already calls `SDL_JoystickRumble` or `SDL_GameControllerRumble`. Replace `SDL2.dll` with a current official SDL2 release. No proxy needed. |
| **NOT APPLICABLE** | No SDL2 rumble path the proxy can change. |

The proxy applies only when all of these are true:

1. The game loads `SDL2.dll` as a separate file. It does not work with SDL linked
   into the executable, SDL 1.2 (`SDL.dll`) or SDL3.
2. The game rumbles with `SDL_HapticRumblePlay`.
3. The game does not already use `SDL_JoystickRumble` or `SDL_GameControllerRumble`.
   In that case upgrade SDL2 instead.
4. Your pad is one SDL drives through HIDAPI or RawInput, where the haptic API
   cannot reach it: DualShock 4, DualSense, Switch Pro, Joy-Con, and others.
5. Steam Input is off for the game. If Steam Input turns the pad into an Xbox
   controller, rumble already works there and the proxy changes nothing.

It does not help with:

- DirectInput pads whose force-feedback drivers already work with the haptic API.
- Pads with no rumble motors.
- Real force-feedback effects such as springs or constant force (wheels, flight sticks).
- Games that use XInput or DirectInput directly instead of SDL.
- Games with anti-cheat that checks DLL integrity.

The detector only sees static imports. A game that loads SDL2 at runtime with
`LoadLibrary` shows as not applicable, even if the proxy might work.

## Build

You need:

- [Zig](https://ziglang.org/download/) 0.14 or newer. Unzip it anywhere; no install is needed.
- An official SDL2 2.x release DLL of the game's architecture, from
  [SDL releases](https://github.com/libsdl-org/SDL/releases): `SDL2-2.x.y-win32-x86.zip`
  for 32-bit games, `-win32-x64.zip` for 64-bit. Use 2.0.9 or newer; the latest
  2.x is best because it supports the most pads. `check.ps1` prints the game's
  architecture.

```powershell
.\build.ps1 -SdlDll C:\Downloads\SDL2-2.32.10-win32-x86\SDL2.dll -Zig C:\Tools\zig\zig.exe
```

`-Zig` can be left out when `zig` is on PATH. The script:

1. Reads the export list of the SDL2.dll you passed.
2. Generates `SDL2.def`, which forwards every export except the functions in
   `src/proxy.c`.
3. Compiles the proxy.
4. Checks every export of the result and test-loads it.

The output goes to `build\x86\` or `build\x64\`.

## Install

1. Back up the game's `SDL2.dll`, for example as `SDL2.dll.bak`.
2. Copy `SDL2.dll` and `_SDL2_real.dll` from the build folder into the game folder.
3. Start the game without Steam Input.

Some games ship two executables. For example, Dead Cells has `deadcells.exe` (DirectX, uses
XInput directly) and `deadcells_gl.exe` (OpenGL, uses SDL2). Only the SDL2 one
benefits; `check.ps1` warns when it finds a module that uses XInput or DirectInput directly.

## Uninstall

Delete `SDL2.dll` and `_SDL2_real.dll` from the game folder, then restore your backup as `SDL2.dll`.

## Other compilers

`src/proxy.c` is plain C with no SDL headers, and should also build with MSVC
or MinGW-w64. `build.ps1` supports only Zig, and other compilers are untested.
If you use one:

- Build a DLL from `src/proxy.c` plus a `.def` file like the one `build.ps1`
  writes to the build folder.
- Every forwarded export must end up as `_SDL2_real.<name>` in the final DLL.
  On x86, Zig's linker adds a leading underscore to forward targets, so for Zig
  the script writes `SDL2_real.<name>`. Other linkers may not do this. Check the
  result with `dumpbin /exports SDL2.dll`.

## Files

| File | Purpose |
|---|---|
| `src/proxy.c` | The replaced `SDL_Haptic*` functions. Functions marked `PROXY_API` are exported; everything else is forwarded. |
| `build.ps1` | Generates the `.def` file, compiles with Zig, checks and test-loads the result. |
| `check.ps1` | Reads a game folder and tells whether the proxy applies. |
| `tools/pe.ps1` | Small PE reader (architecture, exports, imports) used by both scripts. |

SDL binaries are not part of this repository. Download them from the official
releases; SDL is distributed under the zlib license.
