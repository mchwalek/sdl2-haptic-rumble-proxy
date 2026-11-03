/*
 * SDL2 haptic rumble proxy.
 *
 * Stands in for SDL2.dll. Every export is forwarded to the real SDL2 (renamed
 * _SDL2_real.dll) except the SDL_Haptic* functions below. When a game opens a
 * haptic device for a joystick that SDL_JoystickRumble can drive, it gets a
 * fake handle whose rumble calls go to SDL_JoystickRumble. That reaches pads
 * the Windows haptic backend cannot (DualShock 4, DualSense, Switch Pro, ...).
 * Joysticks without rumble support, and real haptic handles, use real SDL.
 *
 * Functions marked PROXY_API are exported by this DLL; build.ps1 forwards all
 * other SDL2 exports.
 */
#include <windows.h>
#include <stdint.h>
#include <wchar.h>

#define PROXY_API
#define REAL_DLL L"_SDL2_real.dll"
#define MAX_FAKES 8

typedef struct {
    volatile LONG used;
    void *joystick;
} FakeHaptic;

static FakeHaptic fakes[MAX_FAKES];

extern IMAGE_DOS_HEADER __ImageBase;

static int is_fake(const void *haptic)
{
    const FakeHaptic *h = (const FakeHaptic *)haptic;
    return h >= fakes && h < fakes + MAX_FAKES;
}

/* Loads the real SDL2 from the directory of this DLL, not from the search path. */
static HMODULE real_sdl(void)
{
    static HMODULE module;
    if (!module) {
        wchar_t path[MAX_PATH];
        DWORD n = GetModuleFileNameW((HMODULE)&__ImageBase, path, MAX_PATH);
        if (n == 0 || n >= MAX_PATH)
            return NULL;
        while (n > 0 && path[n - 1] != L'\\' && path[n - 1] != L'/')
            n--;
        if (n + wcslen(REAL_DLL) >= MAX_PATH)
            return NULL;
        wcscpy(path + n, REAL_DLL);
        module = LoadLibraryW(path);
    }
    return module;
}

static FARPROC real_sym(const char *name)
{
    HMODULE module = real_sdl();
    return module ? GetProcAddress(module, name) : NULL;
}

/* Returns from the calling function with the real SDL result, or `fail` if the symbol is missing. */
#define RETURN_REAL(fail, ret, name, params, args)                       \
    do {                                                                 \
        ret (__cdecl *fn_) params = (ret (__cdecl *) params)real_sym(#name); \
        return fn_ ? fn_ args : (fail);                                  \
    } while (0)

#define CALL_REAL_VOID(name, params, args)                               \
    do {                                                                 \
        void (__cdecl *fn_) params = (void (__cdecl *) params)real_sym(#name); \
        if (fn_)                                                         \
            fn_ args;                                                    \
    } while (0)

static int unsupported(const char *function)
{
    int (__cdecl *set_error)(const char *, ...) = (int (__cdecl *)(const char *, ...))real_sym("SDL_SetError");
    if (set_error)
        set_error("%s is not supported on a rumble proxy haptic", function);
    return -1;
}

static int joystick_rumble(void *joystick, uint16_t low, uint16_t high, uint32_t ms)
{
    int (__cdecl *rumble)(void *, uint16_t, uint16_t, uint32_t) =
        (int (__cdecl *)(void *, uint16_t, uint16_t, uint32_t))real_sym("SDL_JoystickRumble");
    return rumble ? rumble(joystick, low, high, ms) : -1;
}

PROXY_API void *SDL_HapticOpenFromJoystick(void *joystick)
{
    /* A zero-strength rumble fails on joysticks without rumble support (and before SDL 2.0.9). */
    if (joystick && joystick_rumble(joystick, 0, 0, 0) == 0) {
        for (int i = 0; i < MAX_FAKES; i++) {
            if (InterlockedCompareExchange(&fakes[i].used, 1, 0) == 0) {
                fakes[i].joystick = joystick;
                return &fakes[i];
            }
        }
    }
    RETURN_REAL(NULL, void *, SDL_HapticOpenFromJoystick, (void *), (joystick));
}

PROXY_API void SDL_HapticClose(void *haptic)
{
    if (is_fake(haptic)) {
        /* No stop call: the game may already have closed the joystick, and SDL stops rumble on close. */
        FakeHaptic *h = haptic;
        h->joystick = NULL;
        InterlockedExchange(&h->used, 0);
        return;
    }
    CALL_REAL_VOID(SDL_HapticClose, (void *), (haptic));
}

PROXY_API int SDL_HapticRumbleSupported(void *haptic)
{
    if (is_fake(haptic))
        return 1;
    RETURN_REAL(-1, int, SDL_HapticRumbleSupported, (void *), (haptic));
}

PROXY_API int SDL_HapticRumbleInit(void *haptic)
{
    if (is_fake(haptic))
        return 0;
    RETURN_REAL(-1, int, SDL_HapticRumbleInit, (void *), (haptic));
}

PROXY_API int SDL_HapticRumblePlay(void *haptic, float strength, uint32_t length)
{
    if (is_fake(haptic)) {
        if (!(strength > 0.0f)) /* also catches NaN */
            strength = 0.0f;
        if (strength > 1.0f)
            strength = 1.0f;
        uint16_t v = (uint16_t)(strength * 0xFFFF + 0.5f);
        return joystick_rumble(((FakeHaptic *)haptic)->joystick, v, v, length);
    }
    RETURN_REAL(-1, int, SDL_HapticRumblePlay, (void *, float, uint32_t), (haptic, strength, length));
}

PROXY_API int SDL_HapticRumbleStop(void *haptic)
{
    if (is_fake(haptic))
        return joystick_rumble(((FakeHaptic *)haptic)->joystick, 0, 0, 0);
    RETURN_REAL(-1, int, SDL_HapticRumbleStop, (void *), (haptic));
}

PROXY_API int SDL_HapticStopAll(void *haptic)
{
    if (is_fake(haptic))
        return joystick_rumble(((FakeHaptic *)haptic)->joystick, 0, 0, 0);
    RETURN_REAL(-1, int, SDL_HapticStopAll, (void *), (haptic));
}

/* The rest of the handle-based API: a fake handle supports rumble only. */

PROXY_API int SDL_HapticIndex(void *haptic)
{
    if (is_fake(haptic))
        return unsupported("SDL_HapticIndex");
    RETURN_REAL(-1, int, SDL_HapticIndex, (void *), (haptic));
}

PROXY_API int SDL_HapticNumEffects(void *haptic)
{
    if (is_fake(haptic))
        return 0;
    RETURN_REAL(-1, int, SDL_HapticNumEffects, (void *), (haptic));
}

PROXY_API int SDL_HapticNumEffectsPlaying(void *haptic)
{
    if (is_fake(haptic))
        return 0;
    RETURN_REAL(-1, int, SDL_HapticNumEffectsPlaying, (void *), (haptic));
}

PROXY_API unsigned int SDL_HapticQuery(void *haptic)
{
    if (is_fake(haptic))
        return 0;
    RETURN_REAL(0, unsigned int, SDL_HapticQuery, (void *), (haptic));
}

PROXY_API int SDL_HapticNumAxes(void *haptic)
{
    if (is_fake(haptic))
        return 0;
    RETURN_REAL(-1, int, SDL_HapticNumAxes, (void *), (haptic));
}

PROXY_API int SDL_HapticEffectSupported(void *haptic, void *effect)
{
    if (is_fake(haptic))
        return 0;
    RETURN_REAL(-1, int, SDL_HapticEffectSupported, (void *, void *), (haptic, effect));
}

PROXY_API int SDL_HapticNewEffect(void *haptic, void *effect)
{
    if (is_fake(haptic))
        return unsupported("SDL_HapticNewEffect");
    RETURN_REAL(-1, int, SDL_HapticNewEffect, (void *, void *), (haptic, effect));
}

PROXY_API int SDL_HapticUpdateEffect(void *haptic, int effect, void *data)
{
    if (is_fake(haptic))
        return unsupported("SDL_HapticUpdateEffect");
    RETURN_REAL(-1, int, SDL_HapticUpdateEffect, (void *, int, void *), (haptic, effect, data));
}

PROXY_API int SDL_HapticRunEffect(void *haptic, int effect, uint32_t iterations)
{
    if (is_fake(haptic))
        return unsupported("SDL_HapticRunEffect");
    RETURN_REAL(-1, int, SDL_HapticRunEffect, (void *, int, uint32_t), (haptic, effect, iterations));
}

PROXY_API int SDL_HapticStopEffect(void *haptic, int effect)
{
    if (is_fake(haptic))
        return unsupported("SDL_HapticStopEffect");
    RETURN_REAL(-1, int, SDL_HapticStopEffect, (void *, int), (haptic, effect));
}

PROXY_API void SDL_HapticDestroyEffect(void *haptic, int effect)
{
    if (is_fake(haptic))
        return;
    CALL_REAL_VOID(SDL_HapticDestroyEffect, (void *, int), (haptic, effect));
}

PROXY_API int SDL_HapticGetEffectStatus(void *haptic, int effect)
{
    if (is_fake(haptic))
        return unsupported("SDL_HapticGetEffectStatus");
    RETURN_REAL(-1, int, SDL_HapticGetEffectStatus, (void *, int), (haptic, effect));
}

PROXY_API int SDL_HapticSetGain(void *haptic, int gain)
{
    if (is_fake(haptic))
        return unsupported("SDL_HapticSetGain");
    RETURN_REAL(-1, int, SDL_HapticSetGain, (void *, int), (haptic, gain));
}

PROXY_API int SDL_HapticSetAutocenter(void *haptic, int autocenter)
{
    if (is_fake(haptic))
        return unsupported("SDL_HapticSetAutocenter");
    RETURN_REAL(-1, int, SDL_HapticSetAutocenter, (void *, int), (haptic, autocenter));
}

PROXY_API int SDL_HapticPause(void *haptic)
{
    if (is_fake(haptic))
        return unsupported("SDL_HapticPause");
    RETURN_REAL(-1, int, SDL_HapticPause, (void *), (haptic));
}

PROXY_API int SDL_HapticUnpause(void *haptic)
{
    if (is_fake(haptic))
        return unsupported("SDL_HapticUnpause");
    RETURN_REAL(-1, int, SDL_HapticUnpause, (void *), (haptic));
}
