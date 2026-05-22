#ifndef USA_SOUNDMNG_H
#define USA_SOUNDMNG_H

#include <compiler.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SOUND_PCMSEEK,
    SOUND_PCMSEEK1,
    SOUND_RELAY1,
    SOUND_MAXPCM
};

UINT soundmng_create(UINT rate, UINT ms);
void soundmng_destroy(void);
void soundmng_reset(void);
void soundmng_play(void);
void soundmng_stop(void);
void soundmng_sync(void);
void soundmng_setreverse(BOOL reverse);

BRESULT soundmng_pcmplay(UINT num, BOOL loop);
void soundmng_pcmstop(UINT num);

BRESULT soundmng_initialize(void);
void soundmng_deinitialize(void);

extern int pcm_volume_default;

#ifdef __cplusplus
}
#endif

#endif
